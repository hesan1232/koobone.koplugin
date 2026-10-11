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
-- "attempt to index a nil value" 直接闪退（开始阅读/卷目录/刷新书架等）。
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

-- ============================================================
-- 【视图身份令牌】防异步回填串号
-- ============================================================
-- 与 reading 的 _detail_token 同一手法：在「打开某个界面 / 切到某个视图」时取一个自增号，
-- 异步回调真正回填之前先比对，号变了就放弃此次回填。
--
-- 为什么需要：卷目录（show_series_chapter_dialog）是「先弹 loading → 异步拉目录 → 回填」
-- 的两段式，而回填动作 ShelfView_update(menu, sid) 改的是**共享的** menu。于是存在真实的
-- 串号场景：
--   点系列 A 的「卷目录」（网络慢，1~3s）→ 返回 → 点系列 B 的「卷目录」（命中缓存秒开）
--   → A 的结果姗姗来迟，把已经显示 B 卷目录的页面**替换成 A 的卷列表**。
-- 数据不会串（闭包各自捕获自己的 sid），但「点的是 B、看到的是 A」是明确的错误。
--
-- 只在**视图目标真的变了**时自增（series_id 或 列表/卷视图层级变化），
-- 这样「切换排序」「原地刷新」不会误伤正在加载的目录请求。
local _view_token = 0

local function _bump_view_token()
    _view_token = _view_token + 1
    return _view_token
end

local function _view_token_now()
    return _view_token
end

-- 下载进度弹窗的身份令牌：同一时刻只允许「最后一个」弹窗刷新界面。
-- 场景：已有一个进度弹窗在 0.3s/次轮询，用户又发起了另一个下载（新弹窗），
-- 两个弹窗会同时画同一件事 —— 墨水屏上表现为两块区域交替闪烁。
-- 取号方式与 _detail_token 一致：开新弹窗前自增，旧弹窗的轮询一比对就停。
local _progress_dialog_token = 0

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
        on_close_callback = nil,
        _koobone_closed = false,
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
    end

    function ShelfMenu:onCloseWidget()
        self._koobone_closed = true
        -- 视图已关闭 → 作废所有在途的异步回填（token 比对失败即放弃）。
        -- 这与下面的 cancel_tag 是两道互补的保险：token 管「已发出的回调不落地」，
        -- cancel_tag 管「还没回来的请求直接掐掉」。
        _bump_view_token()
        -- 取消本视图发起的所有异步拉取（卷目录 / 封面）。
        -- 这些流程的 timeout 最长 60s，不取消的话关掉书架后子进程仍在跑、网络仍在占用，
        -- 最后还会回填到一个已经死掉的 menu 上。配套的 loading 对话框由
        -- Async.run 的 opts.on_cancel 负责关闭（取消后 on_done 不再执行）。
        if ok_Async and Async and Async.cancel_tag then
            pcall(function() Async.cancel_tag("shelf") end)
        end
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

-- 列表标题：系列列表用插件标题（opts.title），卷列表用系列名。
-- 搜索/筛选生效时追加 " [关键字]"，与 reading 插件的云端书库同款。
-- 注意：必须在 Menu 创建时或 switchItemTable 时传入才可见 —— 上游 title_bar 只在
-- init()/setTitle() 时重建，直接改 menu.title 不会有任何视觉效果（历史遗留的隐性 no-op）。
local function compute_list_title(opts, bookshelf)
    opts = opts or {}
    local base
    local sid = opts.series_id
    if sid and sid ~= "" then
        local vols = bookshelf and bookshelf:get_series_vols(sid)
        if vols and vols[1] and vols[1].series and vols[1].series ~= "" then
            base = vols[1].series
        else
            base = _t("系列详情")
        end
    else
        base = opts.title or _t("Koobone 书架")
    end
    local f = opts.filter_text
    if f and f ~= "" then
        base = base .. " [" .. f .. "]"
    end
    return base
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

    -- 搜索/筛选关键字（可选）：大小写不敏感的字面子串匹配。
    -- string.find 第 4 参传 true → plain 模式，关键字里的 . ( ) 等按字面处理而非 pattern。
    -- 空串/nil = 不过滤。系列列表匹配「标题 + 作者」，卷列表匹配「卷名」。
    local filter = opts.filter_text
    if filter == "" then filter = nil end
    if filter then filter = string.lower(filter) end
    local function match_filter(...)
        if not filter then return true end
        for i = 1, select("#", ...) do
            local s = select(i, ...)
            if s and s ~= "" and string.find(string.lower(tostring(s)), filter, 1, true) then
                return true
            end
        end
        return false
    end

    -- 视图 2：目录页（卷列表）
    local series_id = opts.series_id
    if series_id and series_id ~= "" then
        local ok_v, vols = pcall(function()
            return bookshelf:get_series_vols(series_id)
        end)
        if not ok_v then vols = nil end
        if not vols then return items end

        -- 搜索过滤：在**排序后的完整列表**上过滤，保证结果顺序仍按当前排序键
        if filter then
            local kept = {}
            for _, vol in ipairs(vols) do
                if match_filter(vol.title, vol.vol_name) then
                    kept[#kept + 1] = vol
                end
            end
            vols = kept
        end
        if #vols == 0 then return items end

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
    -- 搜索过滤（匹配标题 + 作者）
    if filter then
        local kept = {}
        for _, s in ipairs(series_list) do
            if match_filter(s.title, s.author) then kept[#kept + 1] = s end
        end
        series_list = kept
    end
    for _idx, series in ipairs(series_list) do
        -- 系列封面：用伪 vol 结构（file_md5 = series_<id>）
        -- ⚠️ 注意这个 `series_` 前缀是「封面文件名的伪 fmd」，与 bookshelf.lua 里
        -- LOCAL_VOL_INDEX 的键 `"series:"..id`（用冒号）**是两套不同的命名空间**，
        -- 前者拼进封面文件名、后者只是进度索引的 key —— 别把两者统一。
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
    menu:switchItemTable(nil, items, current_first_index)
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
    -- 后台子进程不可用时跳过自动封面下载，避免阻塞 KOReader 界面
    if not (ok_Async and Async and Async.is_available and Async.is_available()) then
        Log.warn("[KooboneCover] 后台子进程不可用，跳过自动封面缓存以免阻塞 KOReader")
        return
    end

    -- 逐个下载：每次下载一个封面后 yield 给 UI，避免长时间阻塞
    local idx = 1
    local last_refresh = 0
    local function download_next()
        if not menu or menu._koobone_closed then return end
        if idx > #pending then
            -- 全部下载完成：最后再刷新一次兜底（避免某些成功下载因节流被跳过）
            pcall(function() refresh_current(menu) end)
            return
        end
        local item = pending[idx]
        idx = idx + 1
        local covers_dir = H.get_covers_dir()
        H.make_dir(covers_dir)
        local cover_path = H.join_path(covers_dir, H.cover_filename_for(item.fmd))
        if not H.file_exists(cover_path) then
            Log.debug("[KooboneCover] 开始下载 fmd=", tostring(item.fmd), "url=", tostring(item.url))
            -- 把单张下载放到子进程，避免 SSL 握手阻塞 UI 线程
            -- 使用 bookshelf:download_cover_file（SSL bypass + 正确 headers）
            Async.run(function()
                local success, reason = bookshelf:download_cover_file(item.url, cover_path)
                return { success = success, reason = reason }
            end, function(ok, result, err)
                if menu._koobone_closed then return end
                if ok and result and result.success and H.file_exists(cover_path) then
                    bookshelf.covers[item.fmd] = cover_path
                    Log.debug("[KooboneCover] 下载成功 fmd=", tostring(item.fmd))
                    -- 2 秒节流刷新，避免 50 张封面刷 50 次水墨屏闪烁
                    local now = os.time()
                    if now - last_refresh >= 2 then
                        last_refresh = now
                        pcall(function() refresh_current(menu) end)
                    end
                else
                    -- 下载失败：记录原因，方便排查（SSL/Referer/网络）
                    local reason = (result and result.reason) or err or "未知"
                    Log.warn("[KooboneCover] 封面下载失败 fmd=" .. tostring(item.fmd)
                        .. " url=" .. tostring(item.url)
                        .. " reason=" .. tostring(reason))
                end
                -- 下载完成后再调度下一个，给 UI 喘息
                if not menu._koobone_closed and ok_UIManager then
                    UIManager:scheduleIn(0.05, download_next)
                end
                -- tag=shelf：书架菜单关闭时取消这张封面的下载（timeout 45s，
                -- 不取消的话关掉书架后子进程还会继续跑）。无 loading 界面，故不需要 on_cancel。
            end, { timeout = 45, poll_interval = 0.3, tag = "shelf" })
            return
        else
            -- 本地已有 → 回填内存缓存即可。如果内存里没有，说明是重启后首次加载，
            -- 这时也需要刷新一次让 ImageWidget 读取到本地 cover_path。
            if not bookshelf.covers[item.fmd] then
                bookshelf.covers[item.fmd] = cover_path
                local now = os.time()
                if now - last_refresh >= 2 then
                    last_refresh = now
                    pcall(function() refresh_current(menu) end)
                end
            end
        end
        -- 调度下一个下载（让 UI 有机会处理事件）
        if ok_UIManager then
            UIManager:scheduleIn(0.05, download_next)
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
-- 刷新回调
-- ============================================================
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
    -- 【不要写 timeout = 0】KOReader 的 InfoMessage:onShow 是 `if self.timeout then
    -- UIManager:scheduleIn(self.timeout, close) end`，而 Lua 里 0 为真 → 传 0 等于
    -- 「排一个 0 秒后的关闭定时器」= 弹出即消失。一次刷新最长 120s（含重试退避），
    -- 用户在整段时间里看不到任何反馈。这里不设 timeout，交给 on_done / on_cancel 主动关。
    busy = InfoMessage:new{ text = _t("正在刷新书架...") }
    UIManager:show(busy)
    -- showBusy 之后立刻 forceRePaint，保证 busy 对话框先画出来
    -- Async.run 放到下一个 tick（scheduleIn 0），避免 fork 子进程前 paint 队列被卡住
    if ok_UIManager then pcall(function() UIManager:forceRePaint() end) end
    if not ok_Async then
        -- 同步降级：refresh 会在 UI 线程一路跑完（阻塞），此时 busy 已经 forceRePaint 过，
        -- 留着它当「卡住但至少知道在做事」的提示；跑完再关（原先在调用前就关掉，
        -- 于是阻塞期间屏幕上什么都没有）。
        local ok, result_or_err = pcall(function()
            return plugin_ref.bookshelf and plugin_ref.bookshelf:refresh(true)
        end)
        do_close_busy()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_t("刷新失败:\n%1"), tostring(result_or_err)),
                timeout = 3,
            })
            return
        end
        -- 同步模式：result_or_err 是 refresh 的复合 table
        -- 用 apply_refresh_result 把 series + all_vols 写入父进程内存
        if type(result_or_err) == "table" and result_or_err.series then
            pcall(function()
                plugin_ref.bookshelf:apply_refresh_result(result_or_err)
            end)
        end
        refresh_current(menu)
        return
    end
    -- 下一个 tick 再 fork 子进程，让 busy 先渲染
    UIManager:scheduleIn(0, function()
        -- 这一 tick 之间菜单可能已被关掉（此时 cancel_tag("shelf") 早已跑过、但本句柄
        -- 还没登记，取消不到）→ 直接放弃并收掉 busy，不做无谓的网络刷新。
        if menu and menu._koobone_closed then
            do_close_busy()
            return
        end
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
            -- 异步模式：用 apply_refresh_result 把子进程返回的 series + all_vols
            -- 重新写入父进程内存，解决 Async.run 跨进程隔离
            if type(result) == "table" and result.series then
                pcall(function()
                    plugin_ref.bookshelf:apply_refresh_result(result)
                end)
            end
            -- 成功：动态更新当前菜单内容（保持页码/焦点）
            refresh_current(menu)
        end, {
            timeout = 120,
            poll_interval = 0.3,
            -- 取消路径（菜单关闭 → cancel_tag("shelf")；退出 → cancel_all）不会执行
            -- on_done，busy 必须在这里关，否则墨水屏永久残留「正在刷新书架...」。
            tag = "shelf",
            on_cancel = do_close_busy,
        })
    end)
end

-- ============================================================
-- 排序 / 搜索 对话框（书架主页与卷列表共用一套交互）
--   交互参考 reading 插件书架菜单：同一个键再点一次翻转正/倒序，
--   当前生效的键标 ✓，未生效的键显示它的默认方向。
--   系列列表的排序持久化在 settings:shelf.sort_order + shelf.sort_asc；
--   卷列表用独立的 settings:shelf.vol_sort + vol_sort_asc（互不影响）。
-- ============================================================
local _sort_dialog = nil
local function close_sort_dialog()
    if _sort_dialog and ok_UIManager then
        pcall(function() UIManager:close(_sort_dialog) end)
    end
    _sort_dialog = nil
end

-- 各排序键的默认方向：名称正序，其余倒序（最新/最近阅读在前）
local function shelf_sort_default_asc(key) return key == "vol_name" end
local function vol_sort_default_asc(key) return key ~= "update_time" end

-- 系列列表排序对话框
local function show_sort_dialog(opts, menu)
    if not (ok_UIManager and ok_ButtonDialog) then return end
    local plugin = opts and opts.plugin
    if not plugin then return end
    local settings = plugin.settings
    if not settings then return end
    close_sort_dialog()
    local current_sort = settings:get_shelf_sort()

    local function toggle_sort(key)
        close_sort_dialog()
        local bookshelf = plugin.bookshelf
        if current_sort == key then
            -- 已是当前键：翻转方向（持久化后原地重刷，不重排缓存）
            local asc = settings:get_shelf_sort_asc()
            if asc == nil then asc = shelf_sort_default_asc(key) end
            settings:set_shelf_sort_asc(not asc)
            pcall(function() settings:flush() end)
            if bookshelf then bookshelf.dirty = true end
        else
            -- 换键：sort_vols 内部会 set_shelf_sort（顺带清掉方向）+ flush + 标 dirty
            if bookshelf and bookshelf.sort_vols then
                pcall(function() bookshelf:sort_vols(key) end)
            else
                settings:set_shelf_sort(key)
                pcall(function() settings:flush() end)
            end
        end
        refresh_current(menu)
    end

    local function sort_btn_text(key, label)
        local asc = settings:get_shelf_sort_asc()
        if asc == nil then asc = shelf_sort_default_asc(key) end
        return label .. "（" .. (asc and _t("正序") or _t("倒序")) .. "）"
            .. (current_sort == key and "  ✓" or "")
    end

    _sort_dialog = ButtonDialog:new{
        title = _t("排序方式"),
        buttons = {
            {
                { text = sort_btn_text("last_read", _t("按最后阅读")), callback = function() toggle_sort("last_read") end },
            },
            {
                { text = sort_btn_text("uptime", _t("按更新时间")), callback = function() toggle_sort("uptime") end },
            },
            {
                { text = sort_btn_text("vol_name", _t("按名称")), callback = function() toggle_sort("vol_name") end },
            },
            {
                { text = _t("取消"), callback = close_sort_dialog },
            },
        },
    }
    UIManager:show(_sort_dialog)
end

-- 卷列表排序对话框（独立于书架排序）
local function show_vol_sort_dialog(opts, menu)
    if not (ok_UIManager and ok_ButtonDialog) then return end
    local plugin = opts and opts.plugin
    if not plugin then return end
    local settings = plugin.settings
    if not settings then return end
    close_sort_dialog()
    local current_sort = settings:get_vol_sort()

    local function toggle_sort(key)
        close_sort_dialog()
        local bookshelf = plugin.bookshelf
        if current_sort == key then
            local asc = settings:get_vol_sort_asc()
            if asc == nil then asc = vol_sort_default_asc(key) end
            settings:set_vol_sort_asc(not asc)
        else
            settings:set_vol_sort(key)   -- 同时清掉方向
        end
        pcall(function() settings:flush() end)
        if bookshelf then bookshelf.dirty = true end
        refresh_current(menu)
    end

    local function sort_btn_text(key, label)
        local asc = settings:get_vol_sort_asc()
        if asc == nil then asc = vol_sort_default_asc(key) end
        return label .. "（" .. (asc and _t("正序") or _t("倒序")) .. "）"
            .. (current_sort == key and "  ✓" or "")
    end

    _sort_dialog = ButtonDialog:new{
        title = _t("卷排序方式"),
        buttons = {
            {
                { text = sort_btn_text("vol_snumber", _t("按卷序")), callback = function() toggle_sort("vol_snumber") end },
            },
            {
                { text = sort_btn_text("vol_name", _t("按名称")), callback = function() toggle_sort("vol_name") end },
            },
            {
                { text = sort_btn_text("update_time", _t("按更新时间")), callback = function() toggle_sort("update_time") end },
            },
            {
                { text = _t("取消"), callback = close_sort_dialog },
            },
        },
    }
    UIManager:show(_sort_dialog)
end

-- 把搜索关键字写进 opts.filter_text 并**就地重刷列表**（不关菜单、保持同一实例）。
-- 过滤后为空时只提示、保留原列表 —— 否则菜单会因无条目而消失，用户再也没法清筛选。
local function apply_filter(opts, menu, text)
    if not menu then return end
    if text == "" then text = nil end
    opts = opts or menu._shelf_view_opts
    if not opts then return end
    opts.filter_text = text
    -- menu 绑定的就是这张 opts（ShelfView_show 里 menu._shelf_view_opts = opts），
    -- 但保险起见：若两者不是同一张表，也把关键字同步过去，避免刷新时丢筛选。
    if menu._shelf_view_opts and menu._shelf_view_opts ~= opts then
        menu._shelf_view_opts.filter_text = text
    end
    local ropts = menu._shelf_view_opts or opts
    local items = build_items(merge_opts(ropts, { _menu = menu }))
    if not items or #items == 0 then
        if ok_UIManager and ok_InfoMessage then
            UIManager:show(InfoMessage:new{
                text = text and _t("没有匹配的结果，已保留原列表") or _t("列表为空"),
                timeout = 3,
            })
        end
        return
    end
    local bookshelf = ropts.plugin and ropts.plugin.bookshelf
    -- 传新标题（带 [关键字]）→ 上游 switchItemTable 会 setTitle，标题栏才会真正更新
    menu:switchItemTable(compute_list_title(ropts, bookshelf), items, 1)
    pcall(function() trigger_cover_download(ropts, menu) end)
end

-- 搜索对话框（系列列表 / 卷列表共用）
local function show_search_dialog(opts, menu)
    if not ok_UIManager then return end
    local ok_InputDialog, InputDialog = pcall(require, "ui/widget/inputdialog")
    if not ok_InputDialog then return end
    local current = (opts and opts.filter_text) or ""
    local dlg
    dlg = InputDialog:new{
        title = _t("搜索"),
        input = current,
        input_hint = _t("输入关键字，留空清除"),
        buttons = {
            {
                { text = _t("取消"), callback = function()
                    pcall(function() UIManager:close(dlg) end)
                end },
            },
            {
                { text = _t("确定"), is_enter_default = true, callback = function()
                    local text = (dlg:getInputText() or ""):match("^%s*(.-)%s*$") or ""
                    pcall(function() UIManager:close(dlg) end)
                    apply_filter(opts, menu, text)
                end },
            },
        },
    }
    UIManager:show(dlg)
end

-- ============================================================
-- 系列 / 卷 Action 对话框
-- ============================================================
-- 前向声明：local function 顺序加载依赖，show_series_action_dialog 内部会调 show_series_chapter_dialog
local show_series_chapter_dialog
-- 系列 Action 对话框（fanqie 风格）
-- 点击或长按系列后显示：开始阅读 / 卷目录 / 下载全部未缓存 / 刷新系列 / 取消
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
        end, {
            timeout = 60,
            poll_interval = 0.3,
            -- 【取消路径必须自己收尾】Async 被取消时 on_done 不再执行（async.lua 的 poll
            -- 首行 `if handle._cancelled then return end`），所以「正在加载卷列表...」
            -- 只能在 on_cancel 里关。tag 与其它书架流程保持一致：菜单关闭时由
            -- ShelfMenu:onCloseWidget 的 cancel_tag("shelf") 掐掉，否则墨水屏上会
            -- 永久残留 loading（等于假死）。
            tag = "shelf",
            on_cancel = function()
                if loading_msg then pcall(function() UIManager:close(loading_msg) end) end
            end,
        })
    end

    dlg = ButtonDialog:new{
        title = tostring(series.title or _t("未命名系列")),
        buttons = {
            {
                { text = _t("开始阅读"), callback = do_start_reading },
            },
            {
                { text = _t("卷目录"), callback = function()
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

-- 系列卷目录：用 ShelfView_update 切到该系列的"卷目录页面"视图
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
                end, { timeout = 60, poll_interval = 0.5, tag = "shelf" })
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
    -- 【身份令牌】进异步前取号，回填前比对（见 _view_token 的说明）
    local view_token = _view_token_now()
    local loading_msg = InfoMessage:new{ text = _t("正在加载目录...") }
    UIManager:show(loading_msg)
    UIManager:scheduleIn(0, function()
        Async.run(function()
            return bookshelf:get_series_vols(sid, { force = true })
        end, function(ok_run, vols, err)
            pcall(function() UIManager:close(loading_msg) end)
            -- 【身份校验】加载期间用户已切走（换系列 / 返回书架）→ 放弃本次回填，
            -- 否则会把 A 的卷列表贴到 B 的页面上（「点的是 B、看到的是 A」）。
            if _view_token_now() ~= view_token then
                Log.info("卷目录加载完成但视图已切换，放弃回填 series=", sid)
                return
            end
            if not ok_run or not vols or #vols == 0 then
                UIManager:show(InfoMessage:new{
                    text = T(_t("目录加载失败:\n%1"), tostring(err or vols or _t("无数据"))),
                    timeout = 3,
                })
                return
            end
            switch_to_vol_view()
        end, {
            timeout = 60,
            poll_interval = 0.3,
            -- 菜单关闭时取消本次拉取。被取消时 on_done 不会再执行，
            -- 所以「正在加载目录...」必须在这里关掉，否则界面永久卡在 loading。
            tag = "shelf",
            on_cancel = function()
                pcall(function() UIManager:close(loading_msg) end)
            end,
        })
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
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    -- 走 download 模块统一接口：同时清理新命名（系列子目录）和旧命名（根目录）残留
    local removed = false
    if plugin.download and plugin.download.delete_vol_cache then
        removed = pcall(function() return plugin.download:delete_vol_cache(vol, fmd, vol.file_md5) end)
    end
    if not removed then
        -- 兜底：直接走 helper 的路径生成函数，清理新+旧两个位置
        local epub_dir = H.get_epub_dir()
        local subdir = H.epub_subdir_for_vol(vol)
        local new_full_dir = epub_dir
        if subdir and subdir ~= "" then
            new_full_dir = H.join_path(epub_dir, subdir)
        end
        local new_path = H.join_path(new_full_dir, H.epub_filename_for_vol(vol, fmd, vol.file_md5))
        local legacy_path = H.join_path(epub_dir, H.epub_legacy_filename(fmd, vol.file_md5))
        pcall(function() os.remove(new_path) end)
        pcall(function() os.remove(legacy_path) end)
    end
    -- 卷下载索引缓存实时标记：已删除
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
        -- Reader:get_progress() 返回当前会话页码/总页数。
        -- （此前读的是并不存在的 reader.current_page_index / reader.total_pages，永远取到 0）
        local last_page, total_pages = 0, 0
        if reader.get_progress then
            last_page, total_pages = reader:get_progress()
        end
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

    -- 统一结果处理。client:upload_progress 返回 (ok, msg)；
    -- 外层 pcall 只表示"调用没抛异常"，不能当成上传成功。
    local function report(ok_run, ok_up, msg)
        if ok_run and ok_up then
            UIManager:show(InfoMessage:new{ text = _t("云端进度已更新"), timeout = 2 })
        else
            UIManager:show(InfoMessage:new{
                text = T(_t("上传失败:\n%1"), tostring(msg or "未知错误")),
                timeout = 3,
            })
        end
    end

    if not ok_Async then
        local ok_run, ok_up, msg = pcall(function()
            return client:upload_progress(fmd, last_page, total_pages)
        end)
        report(ok_run, ok_up, msg)
        return
    end
    Async.run(function()
        local ok_up, msg = client:upload_progress(fmd, last_page, total_pages)
        return { ok = ok_up == true, msg = tostring(msg or "") }
    end, function(ok_run, result, err_run)
        report(ok_run, result and result.ok, (result and result.msg) or err_run)
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

    -- 【弹窗身份令牌】开新弹窗前取号；本弹窗的所有刷新 / 轮询都要先比对它，
    -- 号变了说明已被更新的弹窗取代 → 自己停下（见 _progress_dialog_token 说明）。
    _progress_dialog_token = _progress_dialog_token + 1
    local dlg_token = _progress_dialog_token

    -- 创建下载进度条 Widget（fanqie 同款：ProgressWidget + 百分比 + 后台/取消按钮）
    local dlg = ok_DLProgress_module:new{
        title = T(_t("下载中：%1"), vol_title),
    }
    -- 关键：标记弹窗可见，让 download_progress 的 setState/_redraw 守卫正确放行
    dlg._visible = true
    UIManager:show(dlg)
    state.setProgressUploadTask(nil)
    -- 本次下载的取消标志。通过 state 的访问器而不是直接写 state.progress_upload_task 裸字段，
    -- 避免绕过模块 API（该槽位历史上被复用作"下载取消 flag"，语义已偏，用局部引用更清晰）。
    local cancel_flag_ref = { cancel_flag = false }
    state.setProgressUploadTask(cancel_flag_ref)

    -- ⚠️ 这两个守卫必须在下面所有闭包**之前**声明：Lua 的 local 从声明语句之后才可见，
    -- 若放在 dlg.on_background / on_cancel 之后，闭包写的就是**全局** _stop / dlg_closed，
    -- 而 poll_progress_once 读的是局部 → "后台运行/取消"停不掉轮询（界面已关但 0.3s 空转）。
    local _stop = false       -- 轮询停止守卫：done/err/cancel/用户手动关 → true，防止无限 scheduleIn
    local dlg_closed = false

    local function on_cancel_clicked()
        cancel_flag_ref.cancel_flag = true
        if plugin.download and fmd ~= "" then
            -- 统一取消入口（download.lua Download:cancel）：pending 直接出队，
            -- 下载中写 IPC cancel.flag 让子进程中止。
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
    local function do_show_update(state_table)
        if dlg_closed or not dlg then return end
        -- 【身份校验】已被更新的弹窗取代 → 绝不再动界面
        if _progress_dialog_token ~= dlg_token then return end
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
        -- 【身份校验】本弹窗已被更新的弹窗取代 → 停轮询（否则两个弹窗同时刷屏）
        if _progress_dialog_token ~= dlg_token then
            _stop = true
            dlg_closed = true
            Log.info("[Koobone] 下载进度弹窗已被新弹窗取代，停止旧弹窗轮询")
            return
        end
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
            table.insert(btns, {
                { text = _t("排序方式"), callback = function()
                    close_dlg()
                    show_vol_sort_dialog(opts, self)
                end },
            })
            table.insert(btns, {
                { text = (opts.filter_text and opts.filter_text ~= "")
                        and (_t("搜索") .. ": " .. opts.filter_text)
                        or _t("搜索"),
                    callback = function()
                        close_dlg()
                        show_search_dialog(opts, self)
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
            table.insert(btns, {
                { text = (opts.filter_text and opts.filter_text ~= "")
                        and (_t("搜索") .. ": " .. opts.filter_text)
                        or _t("搜索"),
                    callback = function()
                        close_dlg()
                        show_search_dialog(opts, self)
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

    local api_key = settings:get_api_key()
    if api_key == "" then
        if ok_InfoMessage then
            UIManager:show(InfoMessage:new{
                text = _t("未配置 API Key，请先在 Koobone 设置中填写"),
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

    -- 标题：系列列表 = opts.title；卷列表 = 系列名。搜索生效时追加 " [关键字]"。
    local menu_title = compute_list_title(opts, bookshelf)

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
                    end, {
                        timeout = 60,
                        poll_interval = 0.3,
                        -- 同 show_series_action_dialog 处：取消后 on_done 不执行，
                        -- 「正在刷新目录...」必须在 on_cancel 里关掉。
                        tag = "shelf",
                        on_cancel = function()
                            pcall(function() UIManager:close(loading) end)
                        end,
                    })
                end
            else
                -- 不 force 时只是刷新 UI（从缓存取最新数据）
                refresh_current(menu_to_refresh)
            end
        else
            -- 书架视图：刷新书架数据
            if force_api then
                -- 【不要在 UI 线程同步 refresh】refresh 内部走 client:request
                -- （3 次重试 + 每次 15s 超时 + socket.sleep 退避），在这里直接 pcall 调用
                -- 会把界面冻住数秒到十几秒。refresh_shelf 已经是「busy 提示 + Async.run
                -- 子进程 + apply_refresh_result 回填」的完整实现，直接复用（顺带去掉一份重复）。
                refresh_shelf(ropts or opts, menu_to_refresh)
            else
                refresh_current(menu_to_refresh)
            end
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
    -- 新视图：作废上一视图在途的异步回填（见 _view_token 的说明）。
    -- 注意必须在 show 之后、trigger_cover_download 之前自增，
    -- 否则这次 show 发起的封面/目录请求会被自己刚自增的号误杀。
    _bump_view_token()
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

    -- 【视图身份令牌】只有**目标视图**真的变了才自增：换系列（sid 变化）或
    -- 列表视图 ⇄ 卷视图 层级切换，都意味着「之前在途的目录请求已不再对应现在这个页面」，
    -- 必须作废（否则会把它回填到新页面上）。排序变化 / 原地刷新（sid 不变）
    -- 不应误伤正在加载的请求 —— 所以这里不用「每次 update 都自增」的粗粒度做法。
    if tostring(old_opts and old_opts.series_id or "") ~= tostring(series_id or "")
        or new_is_vol ~= menu._is_vol_view then
        _bump_view_token()
    end

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

    -- 视图层级变化时同步更新标题（并丢弃上一层的搜索关键字 —— 否则带着
    -- 系列列表的筛选进到卷列表，会把卷全滤掉，看起来像「系列是空的」）。
    if new_is_vol ~= menu._is_vol_view then
        menu._is_vol_view = new_is_vol
        merged.filter_text = nil
    end
    local new_title = compute_list_title(merged, bookshelf)

    -- 更新 menu 绑定的 opts（供后续回调使用）
    merged._menu = menu
    menu._shelf_view_opts = merged

    -- 传 title：上游 switchItemTable 会 title_bar:setTitle，标题栏才会真正刷新
    -- （只改 menu.title 是 no-op，title_bar 只在 init/setTitle 时重建）。
    menu:switchItemTable(new_title, new_items, current_first_index)
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
