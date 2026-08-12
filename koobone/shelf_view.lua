local ok_Blitbuffer, Blitbuffer = pcall(require, "ffi/blitbuffer")
local ok_Device, Device = pcall(require, "device")
local ok_Font, Font = pcall(require, "ui/font")
local ok_Geom, Geom = pcall(require, "ui/geometry")
local ok_GestureRange, GestureRange = pcall(require, "ui/gesturerange")
local ok_HorizontalGroup, HorizontalGroup = pcall(require, "ui/widget/horizontalgroup")
local ok_HorizontalSpan, HorizontalSpan = pcall(require, "ui/widget/horizontalspan")
local ok_InputContainer, InputContainer = pcall(require, "ui/widget/container/inputcontainer")
local ok_LeftContainer, LeftContainer = pcall(require, "ui/widget/container/leftcontainer")
local ok_CenterContainer, CenterContainer = pcall(require, "ui/widget/container/centercontainer")
local ok_FrameContainer, FrameContainer = pcall(require, "ui/widget/container/framecontainer")
local ok_ImageWidget, ImageWidget = pcall(require, "ui/widget/imagewidget")
local ok_Menu, Menu = pcall(require, "ui/widget/menu")
local ok_Size, Size = pcall(require, "ui/size")
local ok_TextBoxWidget, TextBoxWidget = pcall(require, "ui/widget/textboxwidget")
local ok_TextWidget, TextWidget = pcall(require, "ui/widget/textwidget")
local ok_UnderlineContainer, UnderlineContainer = pcall(require, "ui/widget/container/underlinecontainer")
local ok_VerticalGroup, VerticalGroup = pcall(require, "ui/widget/verticalgroup")
local ok_VerticalSpan, VerticalSpan = pcall(require, "ui/widget/verticalspan")
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_Screen_wrapper, _Screen = pcall(require, "device")
local Screen = ok_Screen_wrapper and _Screen and _Screen.screen or nil
local ok_InfoMessage, InfoMessage = pcall(require, "ui/widget/infomessage")
local ok_ButtonDialog, ButtonDialog = pcall(require, "ui/widget/buttondialog")
local ok_ChoiceDialog, ChoiceDialog = pcall(require, "ui/widget/choicedialog")
local ok_ConfirmBox, ConfirmBox = pcall(require, "ui/widget/confirmbox")
local ok_DLProgress, ok_DLProgress_module = pcall(require, "koobone.download_progress")

local ok_gettext, gettext = pcall(require, "gettext")
-- 注意：翻译函数别名不用常用的 `_`，因为 `for _, v in ipairs(t)` 会把 `_` 覆盖成 number，
-- 导致 `_t("xxx")` 变成 `3("xxx")` 直接 crash。用 `_t` 作为别名完全避开这个歧义。
local _t = ok_gettext and gettext or function(text) return text end
local ok_util, util = pcall(require, "util")
-- util.template 在 Kindle 上有时 require "util" 路径不对，
-- 另外 util.template 是在 C (ffiUtil) 中实现的，部分 KOReader 版本没有导出这个符号时
-- util.template 会是 nil。这里写一个纯 Lua fallback 实现（语义完全一致），
-- 避免显示占位符字面量 "%1/%2" 而不被替换：
--   "%1/%2 页" + args("10", "179")  →  "10/179 页"
--   "P%1" + args("10")  →  "P10"
--   "%1 卷" + args(17)  →  "17 卷"
local function _template(t, ...)
    if not t then return "" end
    local args = {...}
    if #args == 0 then return tostring(t) end
    return (tostring(t):gsub("%%(%d)", function(n)
        local i = tonumber(n)
        if i and args[i] ~= nil then return tostring(args[i]) end
        return "%" .. tostring(n)  -- 找不到参数就保留原样
    end))
end
local T = (ok_util and util and util.template) or _template

local H = require("koobone.helper")
local Log = require("koobone.logger")
local state = require("koobone.state")

-- 修复: 此前误用 require("ui/async")，但 KOReader 并无此标准模块，
-- 导致 ok_Async=false / Async=nil，所有 Async.run(...) 调用都会
-- "attempt to index a nil value" 直接闪退（开始阅读/章节目录/刷新书架等）。
-- 正确的异步模块是项目自带的 koobone.async（与 main.lua/download.lua/progress.lua 一致）。
local ok_Async, Async = pcall(require, "koobone.async")

-- ============================================================
-- 前向声明：这些 local 函数在 build_items 的闭包中被引用，
-- 但定义在 build_items 之后。不加前向声明的话，闭包会捕获
-- 全局变量（nil），导致点击时 "attempt to call a nil value"。
-- ============================================================
local show_series_action_dialog
local show_vol_action_dialog
local on_open_vol
local open_download_single
local open_download_batch_ungotten_next
local download_series_all
local delete_local_epub
local confirm_delete_epub
local on_sync_progress_manual
local upload_vol_progress
local show_download_progress
local check_download_state

local ShelfItem
if ok_InputContainer then
    ShelfItem = InputContainer:extend{
        entry = nil,
        menu = nil,
        dimen = nil,
    }
end

if ShelfItem then
    function ShelfItem:init()
        self.ges_events = {
            TapSelect = ok_GestureRange and {GestureRange:new{ges="tap", range=self.dimen}} or nil,
            HoldSelect = ok_GestureRange and {GestureRange:new{ges="hold", range=self.dimen}} or nil,
        }

        local h = self.dimen and self.dimen.h or 100
        local side = ok_Size and math.max(Size.padding.small, Screen and Screen:scaleBySize(4) or 4) or 8
        -- 始终显示封面占位框（纯黑白边框，墨屏兼容），保证每行布局尺寸完全统一
        local cover_h = Screen and math.max(Screen:scaleBySize(58), h - side * 2) or math.max(60, h - side * 2)
        local cover_w = math.max(1, math.floor(cover_h * 0.69))
        local cover = nil

        local cover_path_valid = false
        if self.entry.cover_path and ok_Blitbuffer and ok_ImageWidget then
            if H.file_exists(self.entry.cover_path) then
                cover_path_valid = true
                cover = ImageWidget:new{
                    file = self.entry.cover_path,
                    width = cover_w,
                    height = cover_h,
                    scale_factor = 0,
                    file_do_cache = true,
                }
            end
        end

        -- 无封面或封面文件缺失：统一显示纯黑白边框占位框，保持视觉一致
        if not cover and ok_FrameContainer and ok_CenterContainer and ok_Blitbuffer then
            local bordersize = ok_Size and Size.border.thin or 1
            cover = FrameContainer:new{
                width = cover_w,
                height = cover_h,
                bordersize = bordersize,
                padding = 0,
                margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                color = Blitbuffer.COLOR_BLACK,  -- 纯黑边框（墨屏）
                CenterContainer:new{
                    dimen = Geom and Geom:new{w=cover_w, h=cover_h} or {w=cover_w, h=cover_h},
                    TextWidget and TextWidget:new{text="", face=ok_Font and Font:getFace("smallinfofont", 12)} or nil,
                },
            }
        end

        local gap = ok_Size and Size.padding.large or 12
        local total_w = self.dimen and self.dimen.w or 800
        local text_w = math.max(Screen and Screen:scaleBySize(120) or 150, total_w - cover_w - gap - side * 2)
        local title_font_size = ok_Font and Font:getFace("cfont", math.min(22, Screen and Screen:scaleBySize(18) or 18))
        local info_font_size = ok_Font and Font:getFace("smallinfofont", math.min(17, Screen and Screen:scaleBySize(14) or 14))

        local title
        if ok_TextBoxWidget then
            title = TextBoxWidget:new{
                text = tostring(self.entry.title or _t("未命名")),
                face = title_font_size,
                width = text_w,
                height = math.floor(h * .52),
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                alignment = "left",
                bold = true,
            }
        end

        local details = tostring(self.entry.author or "")
        if details ~= "" and tostring(self.entry.series or "") ~= "" then
            details = details .. " · " .. tostring(self.entry.series or "")
        elseif details == "" then
            details = tostring(self.entry.series or "")
        end
        if details ~= "" and tostring(self.entry.status or "") ~= "" then
            details = details .. " · " .. tostring(self.entry.status or "")
        elseif details == "" then
            details = tostring(self.entry.status or "")
        end

        local info
        if ok_TextBoxWidget then
            info = TextBoxWidget:new{
                text = details,
                face = info_font_size,
                width = text_w,
                height = math.floor(h * .30),
                height_adjust = true,
                height_overflow_show_ellipsis = true,
                alignment = "left",
                fgcolor = ok_Blitbuffer and Blitbuffer.COLOR_DARK_GRAY or nil,
            }
        end

        local text_group
        if ok_VerticalGroup then
            text_group = VerticalGroup:new{
                align = "left",
                title,
                ok_VerticalSpan and VerticalSpan:new{height = math.max(1, Screen and Screen:scaleBySize(2) or 2)} or nil,
                info,
            }
        end

        local row
        if ok_HorizontalGroup then
            row = HorizontalGroup:new{
                align = "center",
                ok_HorizontalSpan and HorizontalSpan:new{width = side} or nil,
            }
            -- 封面占位框始终加入（即使无图时也是统一大小的空框），保证每行宽度对齐
            if cover then
                table.insert(row, cover)
                if ok_HorizontalSpan then
                    table.insert(row, HorizontalSpan:new{width = gap})
                end
            else
                -- 极端 fallback：如果 FrameContainer 也不可用，用空白 span 占位保持尺寸
                if ok_HorizontalSpan then
                    table.insert(row, HorizontalSpan:new{width = cover_w})
                    table.insert(row, HorizontalSpan:new{width = gap})
                end
            end
            if ok_LeftContainer and ok_Geom and text_group then
                table.insert(row, LeftContainer:new{dimen=Geom:new{w=text_w, h=h}, text_group})
            elseif text_group then
                table.insert(row, text_group)
            end
            if ok_HorizontalSpan then
                table.insert(row, HorizontalSpan:new{width = side})
            end
        end

        if ok_UnderlineContainer and ok_Blitbuffer and self.dimen then
            self._underline = UnderlineContainer:new{
                dimen = self.dimen:copy(),
                linesize = ok_Size and Size.line.thin or 1,
                color = Blitbuffer.COLOR_DARK_GRAY,
                padding = 0,
                vertical_align = "center",
                row,
            }
            self[1] = self._underline
        elseif row then
            self[1] = row
        end
    end

    function ShelfItem:onTapSelect(arg, ges)
        local pos = nil
        if ges and ges.pos and self[1] and self[1].dimen then
            local dimen = self[1].dimen
            pos = {
                x=(ges.pos.x - dimen.x) / math.max(1, dimen.w),
                y=(ges.pos.y - dimen.y) / math.max(1, dimen.h),
            }
        end
        if self.menu then
            return Menu.onMenuSelect(self.menu, self.entry, pos)
        end
        return true
    end

    function ShelfItem:onHoldSelect()
        if self.entry and self.entry.hold_callback then
            pcall(self.entry.hold_callback)
        end
        return true
    end

    function ShelfItem:onFocus()
        if self._underline and ok_Blitbuffer then
            self._underline.color = Blitbuffer.COLOR_BLACK
        end
        return true
    end

    function ShelfItem:onUnfocus()
        if self._underline and ok_Blitbuffer then
            self._underline.color = Blitbuffer.COLOR_DARK_GRAY
        end
        return true
    end
end

local ShelfMenu
if ok_Menu then
    ShelfMenu = Menu:extend{
        on_page_changed = nil,
        on_close_callback = nil,
        _koobone_closed = false,
        _suppress_page_callback = false,
        _is_vol_view = false,   -- 当前是否在卷列表层
        _shelf_view_opts = nil, -- 纯函数式上下文表：{ plugin, series_id, skip_refresh, ... }
    }

    -- 覆盖 updateItems：使用 ShelfItem 自定义 widget 渲染（封面 + 详情）
    function ShelfMenu:updateItems(select_number, no_recalculate_dimen)
        local old_dimen = self.dimen and self.dimen:copy()
        self.layout = {}
        self.item_group:clear()
        self.page_info:resetLayout()
        self.return_button:resetLayout()
        self.content_group:resetLayout()
        Menu._recalculateDimen(self, no_recalculate_dimen)
        local offset = (self.page - 1) * self.perpage
        for index_on_page = 1, self.perpage do
            local index = offset + index_on_page
            local entry = self.item_table[index]
            if not entry then break end
            entry.idx = index
            if index == self.itemnumber then select_number = index_on_page end
            local item = ShelfItem:new{
                entry = entry,
                menu = self,
                dimen = self.item_dimen:copy(),
            }
            table.insert(self.item_group, item)
            table.insert(self.layout, {item})
        end
        self:updatePageInfo(select_number)
        self:mergeTitleBarIntoLayout()
        UIManager:setDirty(self.show_parent, function()
            return "ui", old_dimen and old_dimen:combine(self.dimen) or self.dimen
        end)
        if not self._suppress_page_callback and not self._koobone_closed and self.on_page_changed then
            local page = tonumber(self.page) or 1
            local first = (page - 1) * self.perpage + 1
            local last = math.min(#self.item_table, first + self.perpage - 1)
            UIManager:scheduleIn(0, function()
                if not self._koobone_closed and self.on_page_changed then
                    pcall(self.on_page_changed, page, first, last, self)
                end
            end)
        end
    end

    function ShelfMenu:onCloseWidget()
        self._koobone_closed = true
        if self.on_close_callback then
            local callback = self.on_close_callback
            self.on_close_callback = nil
            pcall(callback, self)
        end
        if Menu.onCloseWidget then return Menu.onCloseWidget(self) end
    end
end

-- ============================================================
-- 工具函数：取 opts 上下文（从 menu._shelf_view_opts 或直接传）
-- ============================================================
local function merge_opts(defaults, overrides)
    local r = {}
    if defaults then for k, v in pairs(defaults) do r[k] = v end end
    if overrides then for k, v in pairs(overrides) do r[k] = v end end
    return r
end

local function format_update_time(ts)
    if not ts then return "" end
    ts = tonumber(ts) or 0
    if ts <= 0 then return "" end
    local diff = os.time() - ts
    if diff < 0 then diff = 0 end
    if diff < 60 then
        return _t("刚刚")
    elseif diff < 3600 then
        return string.format(_t("%d 分钟前"), math.floor(diff / 60))
    elseif diff < 86400 then
        return string.format(_t("%d 小时前"), math.floor(diff / 3600))
    elseif diff < 2592000 then
        return string.format(_t("%d 天前"), math.floor(diff / 86400))
    end
    return os.date("%Y-%m-%d", ts)
end

-- ============================================================
-- build_items：两层视图（与 fanqie 的"书架/目录"页面风格一致）
--   1. opts.series_id 为空 → 系列列表（书架主页）
--   2. opts.series_id 非空 → 该系列卷列表（目录页面，非弹窗）
--
-- 目录页（卷列表）item 显示：
--   - author 字段首字符：✓ 表示本地已缓存 (is_vol_downloaded)，
--     ⭐ 表示"上次阅读/当前进度指向的卷"（bookshelf:get_last_read_vol）
--   - author 字段其余部分：阅读进度 N/M（N=当前页 M=总页数，与 ChoiceDialog 版一致）
--   - 点击/长按卷 → show_vol_action_dialog
-- ============================================================
local function build_items(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local items = {}
    if not plugin then return items end
    local settings = plugin.settings
    local bookshelf = plugin.bookshelf
    if not settings or not bookshelf then return items end

    local menu_ref = opts._menu  -- 闭包用（menu 创建后才赋值，闭包执行时读取）

    -- 视图 2：目录页（卷列表）
    local series_id = opts.series_id
    if series_id and series_id ~= "" then
        local ok_v, vols = pcall(function()
            return bookshelf:get_series_vols(series_id)
        end)
        if not ok_v then vols = nil end
        if not vols then return items end

        -- 当前系列的"上次阅读卷"的 fmd：用来打 ⭐ 标记
        local last_read_fmd = nil
        local ok_g, last_vol = pcall(function()
            return bookshelf:get_last_read_vol(series_id)
        end)
        if ok_g and last_vol then
            last_read_fmd = tostring(last_vol.file_md5 or last_vol.fmd or "")
            if last_read_fmd == "" then last_read_fmd = nil end
        end
        if not last_read_fmd then
            -- fallback：遍历找本地 last_readpage 最大的
            local best_fmd = nil
            local best_page = 0
            for _, v in ipairs(vols) do
                local fmd = tostring(v.file_md5 or v.fmd or "")
                local okp, info = pcall(function() return bookshelf:get_vol_progress_info(fmd) end)
                local last_page = 0
                if okp and info then last_page = tonumber(info.last_readpage) or 0 end
                if last_page <= 0 then last_page = tonumber(v.last_readpage) or 0 end
                if last_page > best_page then
                    best_page = last_page
                    best_fmd = fmd
                end
            end
            last_read_fmd = best_fmd
        end

        for _, vol in ipairs(vols) do
            local fmd = tostring(vol.file_md5 or vol.fmd or "")
            local dl = bookshelf:is_vol_downloaded(vol)
            local ok_prog, info = pcall(function() return bookshelf:get_vol_progress_info(fmd) end)
            if not ok_prog then info = nil end
            local last_page = info and tonumber(info.last_readpage) or tonumber(vol.last_readpage) or 0
            local total = info and tonumber(info.total_pages) or tonumber(vol.count_page) or tonumber(vol.total_pages) or 0

            local cover_path = nil
            if vol.cover_url and vol.cover_url ~= "" then
                local ok_cv, cv = pcall(function() return bookshelf:check_cover_exists(vol) end)
                if ok_cv then cover_path = cv end
            end

            local flag_prefixes = {}
            if fmd == last_read_fmd then
                flag_prefixes[#flag_prefixes + 1] = _t("⭐ 当前")
            end
            if dl then
                flag_prefixes[#flag_prefixes + 1] = _t("✓ 已缓存")
            end
            local progress_str = ""
            if last_page > 1 then
                if total > 0 then
                    progress_str = T(_t("进度 %1/%2 页"), tostring(last_page), tostring(total))
                else
                    progress_str = T(_t("进度 P%1"), tostring(last_page))
                end
            end
            local sub_parts = {}
            for _, f in ipairs(flag_prefixes) do sub_parts[#sub_parts + 1] = f end
            local tu = tonumber(vol.time_update or 0) or 0
            if tu > 0 then
                local us = format_update_time(tu)
                if us ~= "" then sub_parts[#sub_parts + 1] = us end
            end
            if progress_str ~= "" then
                sub_parts[#sub_parts + 1] = progress_str
            end

            items[#items + 1] = {
                text = vol.title or vol.vol_name or _t("未命名卷"),
                title = vol.title or vol.vol_name or _t("未命名卷"),
                author = table.concat(sub_parts, " · "),
                series = "",
                status = "",
                cover_path = cover_path,
                callback = function()
                    show_vol_action_dialog(opts, menu_ref, vol)
                end,
                hold_callback = function()
                    show_vol_action_dialog(opts, menu_ref, vol)
                end,
            }
        end
        return items
    end

    -- 视图 1：书架主页（系列列表）
    local series_list = bookshelf:get_series_list()
    if not series_list then return {} end
    for _idx, series in ipairs(series_list) do
        -- 系列封面：用伪 vol 结构（file_md5 = series_<id>）
        -- check_cover_exists 只检查本地已有的，不触发下载（异步下载 trigger_cover_download 做）
        local cover_path = nil
        if series.cover_url and series.cover_url ~= "" then
            local pseudo_vol = {
                file_md5 = "series_" .. tostring(series.id),
                cover_url = series.cover_url,
            }
            local ok_cover, cp = pcall(function()
                return bookshelf:check_cover_exists(pseudo_vol)
            end)
            if ok_cover then cover_path = cp end
        end

        local vol_count = tonumber(series.vol_count or series.comic_count or 0) or 0
        local update_str = format_update_time(series.last_update_time)
        local vol_count_str = string.format(_t("%d 卷"), vol_count)
        local sub_parts = {}
        if series.author and series.author ~= "" then
            sub_parts[#sub_parts + 1] = series.author
        end
        sub_parts[#sub_parts + 1] = vol_count_str
        if update_str ~= "" then
            sub_parts[#sub_parts + 1] = update_str
        end

        items[#items + 1] = {
            text = series.title or _t("未命名系列"),
            title = series.title or _t("未命名系列"),
            author = table.concat(sub_parts, " · "),
            series = "",
            status = "",
            cover_path = cover_path,
            callback = function()
                show_series_action_dialog(opts, menu_ref, series)
            end,
            hold_callback = function()
                show_series_action_dialog(opts, menu_ref, series)
            end,
        }
    end
    return items
end

-- ============================================================
-- refresh_current：当前菜单原地重刷 items（不关闭，保持页码）
-- ============================================================
local function refresh_current(menu)
    if not menu then return end
    -- 问题2修复：用户关闭 shelf（点后台下载进入阅读、或直接关）时，on_close_callback 标记 _koobone_closed=true
    -- 后续下载 on_success / on_fail 回调里再 refresh_current 也不会 setDirty 触发局刷
    if menu._koobone_closed then return end
    local opts = menu._shelf_view_opts
    if not opts then return end
    local items = build_items(merge_opts(opts, { _menu = menu }))
    if not items or #items == 0 then return end
    local current_page = tonumber(menu.page) or 1
    local perpage = menu.perpage or 8
    local current_first_index = (current_page - 1) * perpage + 1
    if current_first_index > #items then
        current_first_index = math.max(1, #items - perpage + 1)
        if current_first_index < 1 then current_first_index = 1 end
    end
    menu._suppress_page_callback = true
    menu:switchItemTable(nil, items, current_first_index)
    menu._suppress_page_callback = false
end

-- ============================================================
-- 异步封面下载：菜单显示后逐个下载缺失封面，不阻塞 UI 渲染
-- ============================================================
local function trigger_cover_download(opts, menu)
    local plugin = opts and opts.plugin
    if not plugin or not plugin.bookshelf then return end
    local bookshelf = plugin.bookshelf
    local should_dl = bookshelf.settings and bookshelf.settings.should_download_covers and bookshelf.settings:should_download_covers()
    if not should_dl then
        Log.debug("[KooboneCover] should_download_covers=false，跳过封面下载")
        return
    end

    -- 收集需要下载封面的 vol 列表
    local pending = {}
    local series_id = opts.series_id
    if series_id then
        -- 卷列表视图：下载该系列各卷封面
        local vols = bookshelf:get_series_vols(series_id) or {}
        for _, vol in ipairs(vols) do
            local fmd = tostring(vol.file_md5 or vol.fmd or "")
            if fmd ~= "" and vol.cover_url and vol.cover_url ~= "" then
                if not bookshelf:check_cover_exists(vol) then
                    table.insert(pending, { fmd = fmd, url = vol.cover_url })
                end
            end
        end
        Log.debug("[KooboneCover] 卷列表视图 series_id=", tostring(series_id), "vols=", #vols, "pending=", #pending)
    else
        -- 系列列表视图：下载系列封面（伪 vol key = series_<id>）
        local series_list = bookshelf:get_series_list() or {}
        for _, series in ipairs(series_list) do
            if series.cover_url and series.cover_url ~= "" then
                local fmd = "series_" .. tostring(series.id)
                local pseudo = { file_md5 = fmd, cover_url = series.cover_url }
                if not bookshelf:check_cover_exists(pseudo) then
                    table.insert(pending, { fmd = fmd, url = series.cover_url })
                end
            end
        end
        Log.debug("[KooboneCover] 系列列表视图 series=", #series_list, "pending=", #pending)
    end

    if #pending == 0 then
        Log.debug("[KooboneCover] 无待下载封面（可能都已缓存或列表为空）")
        return
    end

    -- 逐个下载：每次下载一个封面后 yield 给 UI，避免长时间阻塞
    local idx = 1
    local function download_next()
        if not menu or menu._koobone_closed then return end
        if idx > #pending then
            -- 全部下载完成：最后再刷新一次兜底（避免某些成功下载因 yield 被跳过）
            pcall(function() refresh_current(menu) end)
            return
        end
        local item = pending[idx]
        idx = idx + 1
        local covers_dir = H.get_covers_dir()
        H.make_dir(covers_dir)
        local cover_path = H.join_path(covers_dir, item.fmd .. ".jpg")
        local need_refresh = false
        if not H.file_exists(cover_path) then
            Log.debug("[KooboneCover] 开始下载 fmd=", tostring(item.fmd), "url=", tostring(item.url))
            -- 使用 bookshelf:download_cover_file（SSL bypass + 正确 headers + cookie）
            -- H.download_file 不禁用 SSL 验证，在 Kindle 上会失败
            local dl_ok, dl_ret, dl_err = pcall(function()
                return bookshelf:download_cover_file(item.url, cover_path)
            end)
            if dl_ok and dl_ret and H.file_exists(cover_path) then
                bookshelf.covers[item.fmd] = cover_path
                Log.debug("[KooboneCover] 下载成功 fmd=", tostring(item.fmd))
                -- 修复: 每成功下载一个封面就立即刷新当前页（只刷新当前显示页的 item，
                -- 不触发整屏闪烁、不触发翻页重绘），用户可以看到封面逐张出现，
                -- 而不是要等全部下完或下次打开书架才显示。
                -- 同时符合 project_memory "only refresh when cover download succeeds"。
                need_refresh = true
            else
                -- 下载失败：记录原因，方便排查（SSL/cookie/Referer/网络）
                local reason = "未知"
                if not dl_ok then
                    reason = "pcall异常: " .. tostring(dl_ret)
                elseif not dl_ret then
                    reason = tostring(dl_err or "download_cover_file返回false")
                elseif not H.file_exists(cover_path) then
                    reason = "文件不存在(可能HTTP错误或SSL失败): " .. tostring(dl_err or "")
                end
                Log.warn("[Koobone] 系列封面下载失败 fmd=" .. tostring(item.fmd)
                    .. " url=" .. tostring(item.url)
                    .. " reason=" .. reason)
            end
        else
            -- 本地已有 → 回填内存缓存即可。如果内存里没有，说明是重启后首次加载，
            -- 这时也需要刷新一次让 ImageWidget 读取到本地 cover_path。
            if not bookshelf.covers[item.fmd] then
                bookshelf.covers[item.fmd] = cover_path
                need_refresh = true
            end
        end
        if need_refresh then
            pcall(function() refresh_current(menu) end)
        end
        -- 调度下一个下载（让 UI 有机会处理事件）
        if ok_UIManager then
            UIManager:scheduleIn(0.01, download_next)
        else
            download_next()
        end
    end
    if ok_UIManager then
        UIManager:scheduleIn(0.5, download_next)
    else
        download_next()
    end
end

-- ============================================================
-- 排序 / 刷新 按钮 回调
-- ============================================================
local function update_sort(opts, menu, new_sort)
    local plugin = opts and opts.plugin
    local bookshelf = plugin and plugin.bookshelf
    if bookshelf then bookshelf:sort_vols(new_sort) end
    -- 排序变化后：动态刷新（不关闭菜单）
    refresh_current(menu)
end

local function refresh_shelf(opts, menu)
    local plugin = opts and opts.plugin
    if not plugin then return end
    if not (ok_UIManager and ok_InfoMessage) then return end
    local busy
    local plugin_ref = plugin
    local function do_close_busy()
        if busy then
            pcall(function() UIManager:close(busy) end)
            busy = nil
        end
    end
    busy = InfoMessage:new{ text = _t("正在刷新书架..."), timeout = 0 }
    UIManager:show(busy)
    -- showBusy 之后立刻 forceRePaint，保证 busy 对话框先画出来
    -- Async.run 放到下一个 tick（scheduleIn 0），避免 fork 子进程前 paint 队列被卡住
    if ok_UIManager then pcall(function() UIManager:forceRePaint() end) end
    if not ok_Async then
        do_close_busy()
        local ok, err = pcall(function()
            return plugin_ref.bookshelf and plugin_ref.bookshelf:refresh(true)
        end)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_t("刷新失败:\n%1"), tostring(err)),
                timeout = 3,
            })
            return
        end
        refresh_current(menu)
        return
    end
    -- 下一个 tick 再 fork 子进程，让 busy 先渲染
    UIManager:scheduleIn(0, function()
        Async.run(function()
            if plugin_ref.bookshelf then
                return plugin_ref.bookshelf:refresh(true)
            end
            return nil, "bookshelf missing"
        end, function(ok_run, result, err_run)
            do_close_busy()
            if not ok_run then
                UIManager:show(InfoMessage:new{
                    text = T(_t("刷新失败:\n%1"), tostring(result)),
                    timeout = 3,
                })
                return
            end
            if not result then
                UIManager:show(InfoMessage:new{
                    text = T(_t("刷新失败:\n%1"), tostring(err_run)),
                    timeout = 3,
                })
                return
            end
            -- 成功：动态更新当前菜单内容（保持页码/焦点）
            refresh_current(menu)
        end, { timeout = 120, poll_interval = 0.3 })
    end)
end

local _sort_dialog = nil
local function close_sort_dialog()
    if _sort_dialog and ok_UIManager then
        pcall(function() UIManager:close(_sort_dialog) end)
    end
    _sort_dialog = nil
end

local function show_sort_dialog(opts, menu)
    if not (ok_UIManager and ok_ButtonDialog) then return end
    local plugin = opts and opts.plugin
    if not plugin then return end
    close_sort_dialog()
    local settings = plugin.settings
    local current_sort = settings and settings:get_shelf_sort() or "last_read"

    local function do_sort(sort_key)
        close_sort_dialog()
        update_sort(opts, menu, sort_key)
    end

    local function choose(choice)
        if choice == "last_read" then
            do_sort("last_read")
        elseif choice == "uptime" then
            do_sort("uptime")
        elseif choice == "vol_name" then
            do_sort("vol_name")
        end
    end

    _sort_dialog = ButtonDialog:new{
        title = _t("排序方式"),
        buttons = {
            {
                {
                    text = _t("按最后阅读") .. (current_sort == "last_read" and "  ✓" or ""),
                    callback = function() choose("last_read") end,
                },
            },
            {
                {
                    text = _t("按更新时间") .. (current_sort == "uptime" and "  ✓" or ""),
                    callback = function() choose("uptime") end,
                },
            },
            {
                {
                    text = _t("按名称") .. (current_sort == "vol_name" and "  ✓" or ""),
                    callback = function() choose("vol_name") end,
                },
            },
            {
                {
                    text = _t("取消"),
                    callback = close_sort_dialog,
                },
            },
        },
    }
    UIManager:show(_sort_dialog)
end

-- ============================================================
-- 系列 / 卷 Action 对话框
-- ============================================================
-- 前向声明：local function 顺序加载依赖，show_series_action_dialog 内部会调 show_series_chapter_dialog
local show_series_chapter_dialog
-- 系列 Action 对话框（fanqie 风格）
-- 点击或长按系列后显示：开始阅读 / 章节目录 / 下载全部未缓存 / 刷新系列 / 取消
show_series_action_dialog = function(opts, menu, series)
    if not (ok_UIManager and ok_ButtonDialog) then return end
    local plugin = opts and opts.plugin
    if not plugin or not series then return end
    local bookshelf = plugin.bookshelf
    local dlg
    local function close_dlg()
        if dlg then pcall(function() UIManager:close(dlg) end) end
        dlg = nil
    end

    local function do_start_reading()
        close_dlg()
        if not bookshelf then
            if ok_UIManager and ok_InfoMessage then
                UIManager:show(InfoMessage:new{ text = _t("书架模块未加载"), timeout = 2 })
            end
            return
        end
        -- 选最新可读卷：1. 有本地阅读过的 → 最近阅读  2. 否则最新 time_update 且已下载
        -- 异步获取 vols（避免阻塞）
        -- 修复: 保存 loading_msg 引用，回调里 UIManager:close(loading_msg) 精确关闭；
        -- 之前 UIManager:close() 不带参数是 no-op，loading 提示会一直留在屏幕上
        local loading_msg
        if ok_UIManager and ok_InfoMessage then
            loading_msg = InfoMessage:new{ text = _t("正在加载卷列表...") }
            UIManager:show(loading_msg)
        end
        Async.run(function()
            return bookshelf:get_latest_readable_vol(series.id)
        end, function(ok_run, vol_or_nil, kind)
            if loading_msg then pcall(function() UIManager:close(loading_msg) end) end
            if not ok_run or not vol_or_nil then
                if ok_UIManager and ok_InfoMessage then
                    UIManager:show(InfoMessage:new{ text = _t("未找到可阅读的卷"), timeout = 2 })
                end
                return
            end
            -- 所有卷都没下载 → 提示用户先下载
            local dl = bookshelf:is_vol_downloaded(vol_or_nil)
            if kind == "none" or not dl then
                if ok_UIManager and ok_InfoMessage then
                    UIManager:show(InfoMessage:new{ text = T(_t("请先下载该卷：\n%1"), tostring(vol_or_nil.title or "")), timeout = 3 })
                end
                -- 直接打开该卷的操作菜单（含下载）
                pcall(function() show_vol_action_dialog(opts, menu, vol_or_nil) end)
                return
            end
            -- 已下载 → 打开 EPUB
            local ok_open, err_open = pcall(function()
                plugin:open_comic(vol_or_nil)
            end)
            if not ok_open then
                if ok_UIManager and ok_InfoMessage then
                    UIManager:show(InfoMessage:new{ text = _t("打开失败：") .. tostring(err_open or ""), timeout = 3 })
                end
            end
        end, { timeout = 60, poll_interval = 0.3 })
    end

    dlg = ButtonDialog:new{
        title = tostring(series.title or _t("未命名系列")),
        buttons = {
            {
                { text = _t("开始阅读"), callback = do_start_reading },
            },
            {
                { text = _t("章节目录"), callback = function()
                    close_dlg()
                    show_series_chapter_dialog(opts, menu, series)
                end },
            },
            {
                { text = _t("下载全部未缓存"), callback = function()
                    close_dlg()
                    download_series_all(opts, menu, series)
                end },
            },
            {
                { text = _t("刷新系列"), callback = function()
                    close_dlg()
                    -- 清该系列的 3 层缓存，强制重拉
                    if bookshelf then
                        pcall(function() bookshelf:invalidate_series_cache(series.id) end)
                        if ok_UIManager and ok_InfoMessage then
                            UIManager:show(InfoMessage:new{ text = _t("已刷新，下次打开会重新加载"), timeout = 2 })
                        end
                    end
                end },
            },
            {
                { text = _t("取消"), callback = close_dlg },
            },
        },
    }
    UIManager:show(dlg)
end

-- 系列章节目录：用 ShelfView_update 切到该系列的"卷目录页面"视图
--   与 fanqie 风格一致：目录是完整页面（不是弹窗），左上角按钮返回书架主页。
--   卷条目带 ⭐ 当前/✓ 已缓存/阅读进度 N/M 标识（build_items 卷视图分支负责）。
-- 关键修复：用 peek_series_vols 只查缓存（L1/L2/L3）不触发 API，避免缓存 miss 时
--   同步阻塞 15s 打 API 导致 UI 卡死"出不来"。缓存 miss 时走异步 loading 路径。
show_series_chapter_dialog = function(opts, menu, series)
    if not menu or not ShelfView_update then return end
    if not series then return end
    local sid = tostring(series.id or "")
    if sid == "" then
        -- fallback：部分系列 sid 为空，用系列名作为缓存键（sna）
        local sna = tostring(series.sna or series.title or "")
        if sna == "" then return end
        sid = sna
    end

    local plugin = opts and opts.plugin
    local bookshelf = plugin and plugin.bookshelf
    if not bookshelf then return end

    local function switch_to_vol_view()
        ShelfView_update(menu, sid)
    end

    -- ① 只查缓存（L1/L2/L3），不触发 API 请求 → 避免同步阻塞卡死 UI
    local cached = nil
    if bookshelf.peek_series_vols then
        local ok_pk, result = pcall(function() return bookshelf:peek_series_vols(sid) end)
        if ok_pk and result and #result > 0 then
            cached = result
        end
    end

    if cached and #cached > 0 then
        -- 缓存命中：秒开卷目录视图（0 等待）
        switch_to_vol_view()

        -- ② stale-while-revalidate：缓存过期时后台异步 force 刷新
        -- 修复 pcall 返回值 bug：pcall 返回 (true, result)，之前只取了第一个 true
        local ok_stale, is_stale = pcall(function() return bookshelf:is_series_vols_stale(sid) end)
        if ok_stale and is_stale and ok_UIManager and ok_Async then
            Log.info("目录缓存已过期，秒开旧数据并后台刷新: series=", sid)
            UIManager:scheduleIn(0.1, function()
                Async.run(function()
                    return bookshelf:get_series_vols(sid, { force = true })
                end, function(ok_r, new_vols, err_r)
                    if ok_r and new_vols and #new_vols > 0 then
                        Log.info("目录后台刷新成功: series=", sid, "count=", #new_vols)
                        pcall(function() refresh_current(menu) end)
                    else
                        Log.warn("目录后台刷新失败: series=", sid, "err=", tostring(err_r))
                    end
                end, { timeout = 60, poll_interval = 0.5 })
            end)
        end
        return
    end

    -- ③ 缓存全 miss：显示 loading → 异步拉 API → 成功后切视图
    --    （之前同步调 get_series_vols 会阻塞 15s 等网络，UI 卡死）
    Log.info("目录缓存全 miss，异步加载: series=", sid)
    if not (ok_UIManager and ok_InfoMessage and ok_Async) then
        UIManager:show(InfoMessage:new{ text = _t("目录加载未就绪"), timeout = 2 })
        return
    end
    local loading_msg = InfoMessage:new{ text = _t("正在加载目录...") }
    UIManager:show(loading_msg)
    UIManager:scheduleIn(0, function()
        Async.run(function()
            return bookshelf:get_series_vols(sid, { force = true })
        end, function(ok_run, vols, err)
            pcall(function() UIManager:close(loading_msg) end)
            if not ok_run or not vols or #vols == 0 then
                UIManager:show(InfoMessage:new{
                    text = T(_t("目录加载失败:\n%1"), tostring(err or vols or _t("无数据"))),
                    timeout = 3,
                })
                return
            end
            switch_to_vol_view()
        end, { timeout = 60, poll_interval = 0.3 })
    end)
end

show_vol_action_dialog = function(opts, menu, vol)
    if not (ok_UIManager and ok_ButtonDialog) then return end
    local plugin = opts and opts.plugin
    if not plugin or not vol then return end
    local dlg
    local function close_dlg()
        if dlg then pcall(function() UIManager:close(dlg) end) end
        dlg = nil
    end

    local bookshelf = plugin.bookshelf
    local downloaded = bookshelf and bookshelf:is_vol_downloaded(vol)

    local btns = {}
    table.insert(btns, {
        { text = _t("打开阅读"), callback = function()
            close_dlg()
            on_open_vol(opts, menu, vol)
        end },
    })
    if not downloaded then
        table.insert(btns, {
            { text = _t("下载本卷"), callback = function()
                close_dlg()
                open_download_single(opts, menu, vol)
            end },
        })
        table.insert(btns, {
            { text = _t("预下载：本卷+后续未缓存"), callback = function()
                close_dlg()
                open_download_batch_ungotten_next(opts, menu, vol)
            end },
        })
    else
        table.insert(btns, {
            { text = _t("删除本地缓存"), callback = function()
                close_dlg()
                confirm_delete_epub(opts, menu, vol)
            end },
        })
    end
    table.insert(btns, {
        { text = _t("手动上传云端进度"), callback = function()
            close_dlg()
            on_sync_progress_manual(opts, menu, vol)
        end },
    })
    table.insert(btns, {
        { text = _t("取消"), callback = close_dlg },
    })
    dlg = ButtonDialog:new{
        title = _t("卷操作") .. "：" .. tostring(vol.title or ""),
        buttons = btns,
    }
    UIManager:show(dlg)
end

-- ============================================================
-- 动作实现函数（open_vol / download / delete / sync）
-- ============================================================
on_open_vol = function(opts, menu, vol)
    local plugin = opts and opts.plugin
    if not plugin then return end
    local ok_open, err_open = pcall(function()
        if plugin.open_comic then plugin:open_comic(vol) end
    end)
    if not ok_open then
        Log.error("on_open_vol failed:", tostring(err_open))
        if ok_UIManager and ok_InfoMessage then
            UIManager:show(InfoMessage:new{
                text = T(_t("打开失败:\n%1"), tostring(err_open)),
                timeout = 3,
            })
        end
    end
end

open_download_single = function(opts, menu, vol)
    local plugin = opts and opts.plugin
    if not plugin then return end
    local download = plugin.download
    if not download then
        if ok_UIManager and ok_InfoMessage then
            UIManager:show(InfoMessage:new{ text = _t("下载模块未就绪"), timeout = 3 })
        end
        return
    end
    -- 如果已在下载中，直接打开进度显示（避免重复 enqueue）
    local cur_task = state.getDownloadTask()
    local cur_fmd = cur_task and tostring(cur_task.file_md5 or cur_task.fmd or "")
    local this_fmd = tostring(vol.file_md5 or vol.fmd or "")
    if cur_fmd == this_fmd and cur_task and cur_task.is_downloading then
        -- 已在下载中：展示进度 UI（不重复 enqueue）
        show_download_progress(opts, menu, vol, cur_task)
        return
    end
    -- 设置下载任务状态（内存态，供 UI 轮询；persist_download_task 节流后不会每次写盘）
    state.setDownloadTask({
        file_md5 = this_fmd,
        title = vol.title or vol.vol_name or "",
        current = 0,
        total = 0,
    })

    -- 入队 + 同时显示进度 UI（真实进度：HTTP 实时字节，updateDownloadProgress 已注入队列 download_fn）
    -- show_download_progress 使用同一个 InfoMessage（setDirty）更新文本，不会"不停弹新窗口"
    local initial_task = state.getDownloadTask()
    show_download_progress(opts, menu, vol, initial_task)

    -- 加入下载队列（enqueue 接受 opts.on_success / opts.on_fail 回调）
    download:enqueue(vol, {
        on_success = function(v, epub_path)
            local t = state.getDownloadTask()
            if t then t.success = true end
            state.clearDownloadTask()
            if plugin.bookshelf then
                pcall(function() plugin.bookshelf:markVolDownloaded(v, true) end)
            end
            pcall(function() refresh_current(menu) end)
        end,
        on_fail = function(v, err)
            local t = state.getDownloadTask()
            if t then t.error_msg = tostring(err or "下载失败") end
            state.clearDownloadTask()
            pcall(function() refresh_current(menu) end)
        end,
    })
end

open_download_batch_ungotten_next = function(opts, menu, vol)
    local plugin = opts and opts.plugin
    if not plugin then return end
    local download = plugin.download
    local bookshelf = plugin.bookshelf
    if not download or not bookshelf then
        if ok_UIManager and ok_InfoMessage then
            UIManager:show(InfoMessage:new{ text = _t("下载模块未就绪"), timeout = 3 })
        end
        return
    end
    local series_id = vol.series_id or vol.series
    if not series_id then
        UIManager:show(InfoMessage:new{ text = _t("该卷无系列信息"), timeout = 3 })
        return
    end

    local function do_enqueue(vols2)
        if not vols2 or #vols2 == 0 then return end
        local start_idx2 = nil
        for i, v in ipairs(vols2) do
            if tostring(v.file_md5 or v.fmd or "") == tostring(vol.file_md5 or vol.fmd or "") then
                start_idx2 = i
                break
            end
        end
        if not start_idx2 then start_idx2 = 1 end
        local function on_s(v, p)
            if bookshelf then pcall(function() bookshelf:markVolDownloaded(v, true) end) end
            pcall(function() refresh_current(menu) end)
        end
        local function on_f(v, e)
            pcall(function() refresh_current(menu) end)
        end
        local enqueued2 = 0
        for i = start_idx2, #vols2 do
            local v = vols2[i]
            if not download:is_downloaded(v) then
                download:enqueue(v, { on_success = on_s, on_fail = on_f })
                enqueued2 = enqueued2 + 1
            end
        end
        if enqueued2 == 0 then
            UIManager:show(InfoMessage:new{ text = _t("后续卷都已下载完成"), timeout = 3 })
            return
        end
        UIManager:show(InfoMessage:new{
            text = string.format(_t("已加入下载队列：%d 卷"), enqueued2),
            timeout = 2,
        })
        local t = state.getDownloadTask()
        if t then show_download_progress(opts, menu, vols2[start_idx2], t) end
    end

    local vols = nil
    local ok_get, got = pcall(function()
        return bookshelf:get_series_vols(series_id)
    end)
    if ok_get and got then
        vols = got
    else
        local busy
        busy = InfoMessage:new{ text = _t("正在加载目录..."), timeout = 0 }
        UIManager:show(busy)
        if ok_UIManager then pcall(function() UIManager:forceRePaint() end) end
        if not ok_Async then
            pcall(function() UIManager:close(busy) end)
            UIManager:show(InfoMessage:new{ text = _t("加载目录失败：异步不可用"), timeout = 3 })
            return
        end
        -- 下一个 tick 再 fork，让 busy 先渲染
        UIManager:scheduleIn(0, function()
            Async.run(function()
                return bookshelf:get_series_vols(series_id)
            end, function(ok_run, got_async, err_run)
                pcall(function() UIManager:close(busy) end)
                if not ok_run or not got_async or #got_async == 0 then
                    UIManager:show(InfoMessage:new{
                        text = T(_t("目录加载失败:\n%1"), tostring(err_run or got_async or _t("无数据"))),
                        timeout = 3,
                    })
                    return
                end
                do_enqueue(got_async)
            end, { timeout = 60, poll_interval = 0.3 })
        end)
        return
    end
    do_enqueue(vols)
end

-- 下载本系列全部（使用队列机制，避免并发）
download_series_all = function(opts, menu, series)
    if not (ok_UIManager and ok_InfoMessage) then return end
    local plugin = opts and opts.plugin
    local bookshelf = plugin and plugin.bookshelf
    local download = plugin and plugin.download
    if not download or not bookshelf then
        UIManager:show(InfoMessage:new{ text = _t("下载模块未就绪"), timeout = 3 })
        return
    end
    local series_id = tostring(series.id or "")
    if series_id == "" then return end

    -- 先加载目录（同步缓存命中立刻返回；未命中走后台异步拉取不阻塞UI）
    local busy
    local function close_busy()
        if busy then pcall(function() UIManager:close(busy) end) end
        busy = nil
    end
    local vols = nil
    local ok_get, got = pcall(function()
        return bookshelf:get_series_vols(series_id)
    end)
    if ok_get and got then
        vols = got
    else
        -- 同步获取失败或没缓存：异步拉
        busy = InfoMessage:new{ text = _t("正在加载目录..."), timeout = 0 }
        UIManager:show(busy)
        if ok_UIManager then pcall(function() UIManager:forceRePaint() end) end
        if not ok_Async then
            close_busy()
            UIManager:show(InfoMessage:new{ text = _t("加载目录失败：异步不可用"), timeout = 3 })
            return
        end
        -- 下一个 tick 再 fork，让 busy 先渲染
        UIManager:scheduleIn(0, function()
            Async.run(function()
                return bookshelf:get_series_vols(series_id)
            end, function(ok_run, got_async, err_run)
                close_busy()
                if not ok_run or not got_async or #got_async == 0 then
                    UIManager:show(InfoMessage:new{
                        text = T(_t("目录加载失败:\n%1"), tostring(err_run or got_async or _t("无数据"))),
                        timeout = 3,
                    })
                    return
                end
                -- 真正的 enqueue 逻辑（封装到回调里调用）
                local vv = got_async
                local to_download2 = {}
                for _, v2 in ipairs(vv) do
                    if not download:is_downloaded(v2) then
                        table.insert(to_download2, v2)
                    end
                end
                if #to_download2 == 0 then
                    UIManager:show(InfoMessage:new{ text = _t("该系列已全部下载完成"), timeout = 3 })
                    return
                end
                local function on_each_success(v3, epub_path)
                    if bookshelf then
                        pcall(function() bookshelf:markVolDownloaded(v3, true) end)
                    end
                    pcall(function() refresh_current(menu) end)
                end
                local function on_each_fail(v3, err3)
                    pcall(function() refresh_current(menu) end)
                end
                for _, v2 in ipairs(to_download2) do
                    download:enqueue(v2, { on_success = on_each_success, on_fail = on_each_fail })
                end
                UIManager:show(InfoMessage:new{
                    text = string.format(_t("已加入下载队列：%d 卷"), #to_download2),
                    timeout = 2,
                })
                local t = state.getDownloadTask()
                if t and to_download2[1] then
                    show_download_progress(opts, menu, to_download2[1], t)
                end
            end, { timeout = 60, poll_interval = 0.3 })
        end)
        return
    end

    if not vols or #vols == 0 then
        UIManager:show(InfoMessage:new{ text = _t("该系列无卷可下载"), timeout = 3 })
        return
    end
    -- 过滤掉已下载的卷
    local to_download = {}
    for _, v in ipairs(vols) do
        if not download:is_downloaded(v) then
            table.insert(to_download, v)
        end
    end
    if #to_download == 0 then
        UIManager:show(InfoMessage:new{ text = _t("该系列已全部下载完成"), timeout = 3 })
        return
    end
    local function on_each_success(v, epub_path)
        if bookshelf then
            pcall(function() bookshelf:markVolDownloaded(v, true) end)
        end
        pcall(function() refresh_current(menu) end)
    end
    local function on_each_fail(v, err)
        pcall(function() refresh_current(menu) end)
    end
    for _, v in ipairs(to_download) do
        download:enqueue(v, {
            on_success = on_each_success,
            on_fail = on_each_fail,
        })
    end
    UIManager:show(InfoMessage:new{
        text = string.format(_t("已加入下载队列：%d 卷"), #to_download),
        timeout = 2,
    })
    local t = state.getDownloadTask()
    if t and to_download[1] then
        show_download_progress(opts, menu, to_download[1], t)
    end
end

delete_local_epub = function(opts, menu, vol)
    if not (ok_UIManager and ok_InfoMessage) then return end
    local plugin = opts and opts.plugin
    if not plugin then return end
    local epub_dir = H.get_epub_dir()
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    local epub_path = H.join_path(epub_dir, fmd .. ".epub")
    if H.file_exists(epub_path) then
        local ok_rm, err_rm = pcall(function() os.remove(epub_path) end)
        if not ok_rm then
            UIManager:show(InfoMessage:new{
                text = T(_t("删除失败:\n%1"), tostring(err_rm)),
                timeout = 3,
            })
            return
        end
    end
    -- 章节索引缓存实时标记：已删除
    if plugin.bookshelf then
        pcall(function() plugin.bookshelf:markVolDownloaded(vol, false) end)
    end
    refresh_current(menu)
    UIManager:show(InfoMessage:new{ text = _t("已删除本地缓存"), timeout = 2 })
end

confirm_delete_epub = function(opts, menu, vol)
    if not (ok_UIManager and ok_ConfirmBox) then return end
    local dlg
    dlg = ConfirmBox:new{
        text = T(_t("确认删除本地缓存？\n%1\n（云端书库中内容不会被删除）"), tostring(vol.title or "")),
        ok_callback = function()
            pcall(function() UIManager:close(dlg) end)
            delete_local_epub(opts, menu, vol)
        end,
        cancel_callback = function()
            pcall(function() UIManager:close(dlg) end)
        end,
    }
    UIManager:show(dlg)
end

-- ============================================================
-- 云端进度同步（手动）
-- ============================================================
on_sync_progress_manual = function(opts, menu, vol)
    local plugin = opts and opts.plugin
    if not plugin then return end
    local reader = plugin.reader
    if not reader then
        if ok_UIManager and ok_InfoMessage then
            UIManager:show(InfoMessage:new{ text = _t("阅读模块未就绪"), timeout = 3 })
        end
        return
    end
    -- 如果阅读器有进度，优先上传当前进度；否则上传 bookshelf 中保存的最后进度
    local cur_fmd = vol.file_md5 or vol.fmd or ""
    local cur_reader_fmd = reader.current_vol and (reader.current_vol.file_md5 or reader.current_vol.fmd or "")
    if tostring(cur_reader_fmd) ~= "" and tostring(cur_fmd) == tostring(cur_reader_fmd) then
        local last_page = reader.current_page_index or 0
        local total_pages = reader.total_pages or 0
        upload_vol_progress(opts, menu, vol, { last_page = last_page, total_pages = total_pages })
        return
    end
    -- fallback：bookshelf 里保存的最后阅读进度
    local last_readpage = tonumber(vol.last_readpage) or 0
    local total_pages = tonumber(vol.total_pages) or 0
    upload_vol_progress(opts, menu, vol, { last_page = last_readpage, total_pages = total_pages })
end

upload_vol_progress = function(opts, menu, vol, progress)
    local plugin = opts and opts.plugin
    if not plugin then return end
    if not (ok_UIManager and ok_InfoMessage) then return end
    if ok_Async then
        UIManager:show(InfoMessage:new{ text = _t("正在上传云端进度..."), timeout = 0 })
    end
    local client = plugin.client
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    local last_page = tonumber(progress and progress.last_page) or 0
    local total_pages = tonumber(progress and progress.total_pages) or 0
    if not client then
        UIManager:show(InfoMessage:new{ text = _t("上传失败：网络模块未就绪"), timeout = 3 })
        return
    end
    if fmd == "" then
        UIManager:show(InfoMessage:new{ text = _t("上传失败：卷信息缺失"), timeout = 3 })
        return
    end
    if not ok_Async then
        local ok_up, err_up = pcall(function()
            return client:upload_progress(fmd, last_page, total_pages)
        end)
        if ok_up then
            UIManager:show(InfoMessage:new{ text = _t("云端进度已更新"), timeout = 2 })
        else
            UIManager:show(InfoMessage:new{
                text = T(_t("上传失败:\n%1"), tostring(err_up)),
                timeout = 3,
            })
        end
        return
    end
    Async.run(function()
        return client:upload_progress(fmd, last_page, total_pages)
    end, function(ok_up, result, err_up)
        if ok_up then
            UIManager:show(InfoMessage:new{ text = _t("云端进度已更新"), timeout = 2 })
        else
            UIManager:show(InfoMessage:new{
                text = T(_t("上传失败:\n%1"), tostring(result or err_up)),
                timeout = 3,
            })
        end
    end, { timeout = 30, poll_interval = 0.3 })
end

-- ============================================================
-- 下载进度显示
-- ============================================================
show_download_progress = function(opts, menu, vol, plugin_dl_task)
    local plugin = opts and opts.plugin
    if not plugin then return end
    if not ok_UIManager then return end
    if not (ok_DLProgress and ok_DLProgress_module) then return end
    local fmd = tostring(vol and (vol.file_md5 or vol.fmd) or "")
    local vol_title = tostring(vol and vol.title or vol.vol_name or fmd:sub(1, 8))

    -- 创建下载进度条 Widget（fanqie 同款：ProgressWidget + 百分比 + 后台/取消按钮）
    local dlg = ok_DLProgress_module:new{
        title = T(_t("下载中：%1"), vol_title),
    }
    -- 关键：标记弹窗可见，让 download_progress 的 setState/_redraw 守卫正确放行
    dlg._visible = true
    UIManager:show(dlg)
    state.setProgressUploadTask(nil)
    state.progress_upload_task = { cancel_flag = false }
    local function on_cancel_clicked()
        state.progress_upload_task.cancel_flag = true
        if plugin.download and fmd ~= "" then
            pcall(function() plugin.download:cancel(fmd) end)
        end
    end
    dlg.on_cancel = on_cancel_clicked
    dlg.on_background = function()
        -- 关键：后台运行时标记弹窗不可见+已关闭，阻止后续 setState/_redraw 局刷
        dlg._closed = true
        dlg._visible = false
        _stop = true
        dlg_closed = true
        -- 立即关闭，用 scheduleIn(0) 让它在下一个事件循环立刻执行
        UIManager:scheduleIn(0, function()
            UIManager:close(dlg)
        end)
    end
    local ipc_paths = nil
    if plugin.download and fmd ~= "" then
        local ok_paths, p = pcall(function()
            return plugin.download:ipc_paths(fmd)
        end)
        if ok_paths then ipc_paths = p end
    end
    local cancel_flag_ref = state.progress_upload_task
    local _stop = false   -- 轮询停止守卫：done/err/cancel/用户手动关 → true，防止无限 scheduleIn
    local dlg_closed = false
    local function do_show_update(state_table)
        if dlg_closed or not dlg then return end
        pcall(function() dlg:setState(state_table) end)
    end
    local function close_dlg()
        if _stop and dlg_closed then return end
        _stop = true
        dlg_closed = true
        if dlg then
            pcall(function()
                if dlg._closed then return end
                dlg._closed = true
                dlg._visible = false
                -- 用 scheduleIn(0) 立即关闭（下一个事件循环），避免在下载回调内直接 close 导致的延迟
                UIManager:scheduleIn(0, function()
                    UIManager:close(dlg)
                end)
            end)
        end
        -- 如果 close_dlg 是下载成功 / 失败触发，顺便刷新一下目录页的 ✓ 已缓存 标识
        pcall(function() refresh_current(menu) end)
        pcall(function()
            if plugin.download and ipc_paths then
                plugin.download:ipc_cleanup(ipc_paths)
            end
        end)
    end
    local function poll_progress_once()
        if _stop then return end   -- 任何路径触发了停止，直接 return，不再调度下一次
        if cancel_flag_ref and cancel_flag_ref.cancel_flag then
            _stop = true
            do_show_update({ stage = "cancelled", vol_name = vol_title, current = 0, total = 1, percent = 0 })
            UIManager:scheduleIn(1.0, close_dlg)
            return
        end
        local task = state.getDownloadTask()
        if not task or not task.is_downloading then
            -- 下载结束：成功 / 失败 / 中断 / 取消 → 立即停轮询，再延时 1.2s 关弹窗
            -- 注意：先 _stop=true 再 scheduleIn(close)，防止 0.3s 后下次 poll 又重置 close 时间。
            _stop = true
            local hist = state.getDownloadHistory()
            local found = nil
            for _i, h in ipairs(hist) do
                if tostring(h.file_md5 or h.fmd or "") == fmd then
                    found = h
                    break
                end
            end
            if found and found.success then
                do_show_update({ stage = "done", vol_name = vol_title, current = 1, total = 1, percent = 100 })
            elseif found and found.cancelled then
                do_show_update({ stage = "cancelled", vol_name = vol_title, current = 0, total = 1, percent = 0 })
            elseif found and found.interrupted then
                do_show_update({ stage = "error", vol_name = vol_title, current = 0, total = 1, percent = 0, message = _t("中断，未完成") })
            else
                do_show_update({ stage = "error", vol_name = vol_title, current = 0, total = 1, percent = 0, message = task and (task.error_msg or _t("未完成")) or _t("未完成") })
            end
            UIManager:scheduleIn(1.2, close_dlg)
            return
        end
        local cur = task.current or 0
        local tot = task.total or 0
        if ipc_paths and plugin.download then
            local ok_r, prog = pcall(function()
                return plugin.download:ipc_read_progress(ipc_paths.progress_file)
            end)
            if ok_r and prog and type(prog) == "table" then
                if prog.current then cur = tonumber(prog.current) or cur end
                if prog.total then tot = tonumber(prog.total) or tot end
            end
        end
        do_show_update({
            stage = "download",
            vol_name = vol_title,
            current = cur,
            total = tot,
            download_bytes = cur,
            expected_size = tot,
        })
        -- _stop=false 才调度下一次（正常路径永远 true）
        if not _stop then
            UIManager:scheduleIn(0.3, poll_progress_once)
        end
    end
    -- 用户手动关闭进度条弹窗时（X 按钮 / 菜单返回键）：立即停轮询，
    -- 避免 poll_progress_once 继续 0.3s/次 scheduleIn 死循环刷新界面。
    if dlg then
        local old_close_cb = dlg.on_close_callback
        dlg.on_close_callback = function()
            _stop = true
            dlg_closed = true
            if dlg then
                dlg._closed = true
                dlg._visible = false
            end
            if old_close_cb then pcall(old_close_cb) end
        end
        -- 兜底：cancel 按钮 callback 也要 _stop=true（防止点取消只关了 UI，后台 poll 还跑）
        local old_cancel_cb = dlg.cancel_button_callback
        dlg.cancel_button_callback = function()
            _stop = true
            dlg_closed = true
            if dlg then
                dlg._closed = true
                dlg._visible = false
            end
            -- 取消时立即关闭（不延迟）
            UIManager:scheduleIn(0, function()
                UIManager:close(dlg)
            end)
            if old_cancel_cb then pcall(old_cancel_cb) end
        end
    end
    -- 初始显示 + 开始轮询
    local cur0 = plugin_dl_task and plugin_dl_task.current or 0
    local tot0 = plugin_dl_task and plugin_dl_task.total or 0
    do_show_update({ stage = "prepare", vol_name = vol_title, current = cur0, total = tot0, download_bytes = cur0, expected_size = tot0 })
    UIManager:scheduleIn(0.3, poll_progress_once)
end

-- 向前兼容：检查 download 模块中是否有此任务（用于进度 UI 去重）
check_download_state = function(opts, menu, vol)
    local plugin = opts and opts.plugin
    if not plugin then return end
    local t = state.getDownloadTask()
    if not t then return false end
    local tfmd = tostring(t.file_md5 or t.fmd or "")
    local vfmd = tostring(vol.file_md5 or vol.fmd or "")
    if tfmd == vfmd and not t.finished then
        show_download_progress(opts, menu, vol, t)
        return true
    end
    return false
end

-- ============================================================
-- ShelfMenu 回调（onLeftButtonTap、onClose、onMenuSelect）
-- ============================================================
if ShelfMenu then
    function ShelfMenu:onMenuSelect(entry, pos)
        return Menu.onMenuSelect(self, entry, pos)
    end

    -- 左上角按钮：
    --   - 系列视图（书架）：弹出操作菜单（刷新书架 + 排序方式）
    --   - 卷视图（目录）：弹出操作菜单（返回书架 + 刷新目录），与书架视图保持一致
    function ShelfMenu:onLeftButtonTap()
        local opts = self._shelf_view_opts
        Log.info("[Koobone] onLeftButtonTap called, is_vol_view=", tostring(self._is_vol_view), " ok_UIManager=", tostring(ok_UIManager), " ok_ButtonDialog=", tostring(ok_ButtonDialog))
        if not opts then
            Log.warn("[Koobone] onLeftButtonTap: opts is nil")
            return
        end
        local is_vol_view = self._is_vol_view

        if not (ok_UIManager and ok_ButtonDialog) then
            -- 兜底：如果 ButtonDialog 不可用，直接返回
            Log.warn("[Koobone] onLeftButtonTap: UIManager or ButtonDialog not available")
            if is_vol_view then
                ShelfView_update(self, { _clear_series = true })
            end
            return
        end

        local plugin = opts.plugin
        if not plugin then
            Log.warn("[Koobone] onLeftButtonTap: plugin is nil")
            return
        end
        local dlg
        local function close_dlg()
            if dlg then pcall(function() UIManager:close(dlg) end) end
            dlg = nil
        end

        if is_vol_view then
            -- 卷视图（目录）：弹出菜单
            local btns = {}
            table.insert(btns, {
                { text = _t("返回书架"), callback = function()
                    close_dlg()
                    ShelfView_update(self, { _clear_series = true })
                end },
            })
            table.insert(btns, {
                { text = _t("刷新目录"), callback = function()
                    close_dlg()
                    -- 调用菜单上绑定的刷新方法
                    if self._refresh_data then
                        self._refresh_data(true)
                    end
                end },
            })
            table.insert(btns, { { text = _t("取消"), callback = close_dlg } })
            dlg = ButtonDialog:new{
                title = _t("目录操作"),
                buttons = btns,
            }
        else
            -- 系列视图（书架）：弹出操作菜单
            local btns = {}
            table.insert(btns, {
                { text = _t("刷新书架"), callback = function()
                    close_dlg()
                    refresh_shelf(opts, self)
                end },
            })
            table.insert(btns, {
                { text = _t("排序方式"), callback = function()
                    close_dlg()
                    show_sort_dialog(opts, self)
                end },
            })
            table.insert(btns, { { text = _t("取消"), callback = close_dlg } })
            dlg = ButtonDialog:new{
                title = _t("书架操作"),
                buttons = btns,
            }
        end
        UIManager:show(dlg)
    end

    function ShelfMenu:onClose()
        if self._koobone_closed then return end
        self._koobone_closed = true
        if self.on_close_callback then
            pcall(self.on_close_callback)
        end
        Menu.onClose(self)
    end

    function ShelfMenu:shelf_close_cb()
        return self:onClose()
    end

    function ShelfMenu:onPageChanged(page, first, last, current)
        if self._suppress_page_callback then return end
        if self.on_page_changed then
            local ok_cb = pcall(self.on_page_changed, page, first, last, current)
            if not ok_cb then
                Menu.onPageChanged(self, page, first, last, current)
            end
            return
        end
        Menu.onPageChanged(self, page, first, last, current)
    end
end

-- ============================================================
-- 模块级对外函数（fanqie 风格：ShelfView.show / update / close / refresh_current）
-- ============================================================

-- ShelfView.show(opts) -> 返回 menu 句柄
-- opts 字段: plugin(必填), series_id(可选), skip_refresh(可选), title(可选)
function ShelfView_show(opts_in)
    if not (ok_UIManager and ok_Menu) then return nil end
    local opts = merge_opts(nil, opts_in)
    local plugin = opts.plugin
    local settings = plugin and plugin.settings
    local bookshelf = plugin and plugin.bookshelf
    if not settings or not bookshelf then
        Log.error("ShelfView.show: plugin 缺少 settings/bookshelf")
        return nil
    end

    local uin = settings:get_uin()
    local cookie = settings:get_cookie()
    if uin == "" or cookie == "" then
        if ok_InfoMessage then
            UIManager:show(InfoMessage:new{
                text = _t("未登录，请先在 Koobone 设置中登录"),
                timeout = 3,
            })
        end
        return nil
    end

    local series_id = opts.series_id
    local is_vol_view = series_id ~= nil and series_id ~= ""

    -- 把 opts（上下文）和 menu 绑定，build_items 内部回调需要
    -- 注意：直接传 opts（而非 merge_opts 副本），因为闭包通过 opts._menu 引用 menu，
    -- opts._menu 在下方 menu 创建后才赋值，闭包执行时读取即为正确值
    local items = build_items(opts)
    if not items or #items == 0 then
        if ok_InfoMessage then
            UIManager:show(InfoMessage:new{
                text = is_vol_view
                    and _t("该系列无卷\n请检查网络或返回书架")
                    or _t("书架为空\n请检查网络或登录状态"),
                timeout = 3,
            })
        end
        return nil
    end

    -- 取系列名做标题
    local menu_title
    if not is_vol_view then
        menu_title = opts.title or _t("Koobone 书架")
    else
        local series_title = ""
        local display_vols = bookshelf:get_series_vols(series_id)
        if display_vols and display_vols[1] then
            series_title = display_vols[1].series or ""
        end
        menu_title = series_title ~= "" and series_title or _t("系列详情")
    end

    -- 刷新目录/书架的回调（支持 force=true 强制刷新 API）
    local function refresh_menu_data(menu_to_refresh, force_api)
        if not menu_to_refresh or menu_to_refresh._koobone_closed then return end
        local ropts = menu_to_refresh._shelf_view_opts
        local rplugin = ropts and ropts.plugin
        local rbookshelf = rplugin and rplugin.bookshelf
        if not rbookshelf then return end

        local series_id = ropts.series_id
        if series_id and series_id ~= "" then
            -- 卷列表：强制刷新目录数据
            if force_api then
                if ok_Async and ok_UIManager then
                    local loading = InfoMessage:new{ text = _t("正在刷新目录...") }
                    UIManager:show(loading)
                    Async.run(function()
                        return rbookshelf:get_series_vols(series_id, { force = true })
                    end, function(ok_r, new_vols, err_r)
                        pcall(function() UIManager:close(loading) end)
                        if ok_r and new_vols then
                            Log.info("目录刷新成功: series=", series_id, "count=", #new_vols)
                            refresh_current(menu_to_refresh)
                        else
                            Log.warn("目录刷新失败: ", tostring(err_r))
                            UIManager:show(InfoMessage:new{ text = _t("刷新失败"), timeout = 2 })
                        end
                    end, { timeout = 60, poll_interval = 0.3 })
                end
            else
                -- 不 force 时只是刷新 UI（从缓存取最新数据）
                refresh_current(menu_to_refresh)
            end
        else
            -- 书架视图：刷新书架数据
            if force_api then
                pcall(function() rbookshelf:refresh(true) end)
            end
            refresh_current(menu_to_refresh)
        end
    end

    local menu = ShelfMenu:new{
        title = menu_title,
        item_table = items,
        items_per_page = 8,
        is_borderless = true,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        title_bar_right_icon = "appbar.refresh",
        _is_vol_view = is_vol_view,
        _shelf_view_opts = opts,
        on_close_callback = function()
            -- 标记关闭：后续下载回调 refresh_current() 会看到此标记，不再触发 setDirty 局刷
            menu._koobone_closed = true
            if plugin and plugin._shelf_menu_closed_callback then
                pcall(plugin._shelf_menu_closed_callback)
            end
        end,
        -- 右上角刷新按钮回调
        on_confirm_callback = function()
            refresh_menu_data(menu, true)
        end,
    }
    -- 把 menu 自身塞进 opts._menu，让 refresh_current 的 build_items 回调里能取到 menu 句柄
    opts._menu = menu
    menu._shelf_view_opts = opts
    -- 保存刷新引用，供外部调用
    menu._refresh_data = function(force) refresh_menu_data(menu, force) end

    -- 关键修复：显式设置 onLeftButtonTap，确保 Menu 框架能调用它
    -- （有些 KOReader 版本 Menu 框架只检查实例属性，不检查类方法）
    menu.onLeftButtonTap = function()
        ShelfMenu.onLeftButtonTap(menu)
    end
    Log.info("[Koobone] ShelfMenu created, is_vol_view=", tostring(is_vol_view))

    UIManager:show(menu)
    -- 菜单显示后异步下载缺失封面（不阻塞 UI）
    pcall(function() trigger_cover_download(opts, menu) end)
    return menu
end

-- ShelfView.update(menu, new_opts_or_series_id)：原地更新数据，不关闭，保持页码
-- new_opts 可以是 table（新 opts，比如 series_id 变了）或 string（仅传 series_id）
function ShelfView_update(menu, new_opts_in)
    if not menu then return nil end
    local old_opts = menu._shelf_view_opts
    local plugin = old_opts and old_opts.plugin
    local bookshelf = plugin and plugin.bookshelf
    if not bookshelf then return menu end

    -- 支持第二参数为 string/number（直接传 series_id），与 P0 期间调用兼容
    local new_opts
    if type(new_opts_in) == "string" or type(new_opts_in) == "number" then
        new_opts = { series_id = new_opts_in }
    else
        new_opts = new_opts_in or {}
    end
    local merged = merge_opts(old_opts, new_opts)
    merged._menu = menu

    -- 显式清除 series_id（merge_opts 用 pairs 遍历会跳过 nil，
    -- 直接传 series_id=nil 无法覆盖 old_opts 中的已有值）
    if new_opts._clear_series then
        merged.series_id = nil
        merged._clear_series = nil  -- 清除标志，避免后续传递
    end

    local series_id = merged.series_id
    local new_is_vol = series_id ~= nil and series_id ~= ""

    -- 保存当前页码作为 switchItemTable 定位依据
    local current_page = tonumber(menu.page) or 1
    local perpage = menu.perpage or 8
    local new_items = build_items(merged)
    if not new_items or #new_items == 0 then return menu end

    local current_first_index = (current_page - 1) * perpage + 1
    if current_first_index > #new_items then
        current_first_index = math.max(1, #new_items - perpage + 1)
        if current_first_index < 1 then current_first_index = 1 end
    end

    -- 视图层级变化时同步更新标题
    if new_is_vol ~= menu._is_vol_view then
        menu._is_vol_view = new_is_vol
        if not new_is_vol then
            menu.title = merged.title or _t("Koobone 书架")
        else
            local display_vols = bookshelf:get_series_vols(series_id)
            if display_vols and display_vols[1] then
                local st = display_vols[1].series or ""
                menu.title = st ~= "" and st or _t("系列详情")
            else
                menu.title = _t("系列详情")
            end
        end
    end

    -- 更新 menu 绑定的 opts（供后续回调使用）
    merged._menu = menu
    menu._shelf_view_opts = merged

    menu._suppress_page_callback = true
    menu:switchItemTable(nil, new_items, current_first_index)
    menu._suppress_page_callback = false
    -- 菜单更新后异步下载缺失封面（不阻塞 UI）
    pcall(function() trigger_cover_download(merged, menu) end)
    return menu
end

-- ShelfView.refresh_current(menu)：对外导出的原地刷新
function ShelfView_refresh_current(menu)
    refresh_current(menu)
end

-- ShelfView.close(menu)：关闭菜单
function ShelfView_close(menu)
    if menu and ok_UIManager then
        pcall(function() UIManager:close(menu) end)
    end
end

return {
    show = ShelfView_show,
    update = ShelfView_update,
    close = ShelfView_close,
    refresh_current = ShelfView_refresh_current,
}
