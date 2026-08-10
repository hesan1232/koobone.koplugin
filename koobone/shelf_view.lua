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
local ok_ConfirmBox, ConfirmBox = pcall(require, "ui/widget/confirmbox")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ok_util, util = pcall(require, "util")
local T = ok_util and util.template or function(t, ...) return t end

local H = require("koobone.helper")
local Log = require("koobone.logger")
local state = require("koobone.state")

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

        -- 修复: 操作行（_miu_action_row）用特殊布局渲染，不显示封面/标题
        if self.entry and self.entry._miu_action_row then
            local h = self.dimen and self.dimen.h or 100
            local action_face = ok_Font and Font:getFace("cfont", math.min(20, Screen and Screen:scaleBySize(17) or 17))
            local action_text = self.entry.action_text or self.entry.text or ""
            local row = ok_HorizontalGroup and HorizontalGroup:new{
                align = "center",
                ok_CenterContainer and CenterContainer:new{
                    dimen = Geom and Geom:new{w=self.dimen.w, h=h} or {w=self.dimen.w, h=h},
                    ok_TextWidget and TextWidget:new{text = action_text, face = action_face, bold = true} or nil,
                } or nil,
            } or nil
            if ok_UnderlineContainer and ok_Blitbuffer and row then
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
            return
        end

        local h = self.dimen and self.dimen.h or 100
        local side = ok_Size and math.max(Size.padding.small, Screen and Screen:scaleBySize(4) or 4) or 8
        local show_cover = self.entry.show_cover ~= false
        local cover_h = Screen and math.max(Screen:scaleBySize(58), h - side * 2) or math.max(60, h - side * 2)
        local cover_w = show_cover and math.max(1, math.floor(cover_h * 0.69)) or 0
        local cover = nil

        if show_cover and self.entry.cover_path and ok_Blitbuffer then
            if ok_ImageWidget and H.file_exists(self.entry.cover_path) then
                cover = ImageWidget:new{
                    file = self.entry.cover_path,
                    width = cover_w,
                    height = cover_h,
                    scale_factor = 0,
                    file_do_cache = true,
                }
            elseif ok_FrameContainer and ok_CenterContainer then
                cover = FrameContainer:new{
                    width = cover_w,
                    height = cover_h,
                    bordersize = ok_Size and Size.border.thin or 1,
                    padding = 0,
                    margin = 0,
                    background = Blitbuffer.COLOR_WHITE,
                    CenterContainer:new{
                        dimen = Geom and Geom:new{w=cover_w, h=cover_h} or {w=cover_w, h=cover_h},
                        TextWidget and TextWidget:new{text="", face=ok_Font and Font:getFace("smallinfofont", 12)} or nil,
                    },
                }
            end
        end

        local gap = show_cover and (ok_Size and Size.padding.large or 12) or 0
        local total_w = self.dimen and self.dimen.w or 800
        local text_w = math.max(Screen and Screen:scaleBySize(120) or 150, total_w - cover_w - gap - side * 2)
        local title_font_size = ok_Font and Font:getFace("cfont", math.min(22, Screen and Screen:scaleBySize(18) or 18))
        local info_font_size = ok_Font and Font:getFace("smallinfofont", math.min(17, Screen and Screen:scaleBySize(14) or 14))

        local title
        if ok_TextBoxWidget then
            title = TextBoxWidget:new{
                text = tostring(self.entry.title or _("未命名")),
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
            if cover then
                table.insert(row, cover)
                if ok_HorizontalSpan then
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
            self.menu:onMenuSelect(self.entry, pos)
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
        _action_count = 0,  -- 操作行数量（不计入分页）
    }
end

if ShelfMenu then
    function ShelfMenu:onMenuSelect(entry, pos)
        return Menu.onMenuSelect(self, entry)
    end

    function ShelfMenu:updateItems(select_number, no_recalculate_dimen)
        local old_dimen = self.dimen and self.dimen:copy()
        self.layout = {}
        self.item_group:clear()
        if self.page_info then self.page_info:resetLayout() end
        if self.return_button then self.return_button:resetLayout() end
        if self.content_group then self.content_group:resetLayout() end
        Menu._recalculateDimen(self, no_recalculate_dimen)

        local perpage = self.perpage

        -- 第一阶段：渲染操作区域（分隔符 + 操作行 + 分隔符）
        -- 这些始终显示在每页顶部，占用 perpage 中的位置
        local action_area_end = 0
        local action_area_count = 0
        for i = 1, #self.item_table do
            local entry = self.item_table[i]
            if entry.separator then
                action_area_end = i
                action_area_count = action_area_count + 1
                local ok_Separator, Separator = pcall(require, "ui/widget/separator")
                if ok_Separator then
                    local sep = Separator:new()
                    table.insert(self.item_group, sep)
                    table.insert(self.layout, {sep})
                end
            elseif entry._miu_action_row then
                action_area_end = i
                action_area_count = action_area_count + 1
                if ShelfItem and self.item_dimen then
                    entry.idx = i
                    local item = ShelfItem:new{
                        entry = entry,
                        menu = self,
                        dimen = self.item_dimen:copy(),
                    }
                    table.insert(self.item_group, item)
                    table.insert(self.layout, {item})
                end
            else
                break
            end
        end

        -- 第二阶段：渲染书籍项（分页）
        -- 书籍每页能显示的数量 = perpage - action_area_count
        local book_perpage = perpage - action_area_count
        if book_perpage < 1 then book_perpage = 1 end

        local book_start = action_area_end + 1
        local total_books = #self.item_table - action_area_end
        local total_pages = math.ceil(total_books / book_perpage)
        if total_pages < 1 then total_pages = 1 end
        if self.page > total_pages then self.page = total_pages end
        if self.page < 1 then self.page = 1 end

        local book_offset = (self.page - 1) * book_perpage
        for index_on_page = 1, book_perpage do
            local index = book_start + book_offset + index_on_page - 1
            local entry = self.item_table[index]
            if not entry then break end
            if ShelfItem and self.item_dimen then
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
        end

        -- 设置 self.page_num 以便 Menu 组件的 updatePageInfo 能正确工作
        self.page_num = total_pages

        -- 调用 Menu 组件的 updatePageInfo 来更新分页器
        -- 这样可以正确显示分页器
        if Menu.updatePageInfo then
            Menu.updatePageInfo(self, select_number)
        end

        self:mergeTitleBarIntoLayout()
        if ok_UIManager then
            UIManager:setDirty(self.show_parent, function()
                return "ui", old_dimen and old_dimen:combine(self.dimen) or self.dimen
            end)
        end
        if not self._suppress_page_callback and not self._koobone_closed and self.on_page_changed then
            local page = tonumber(self.page) or 1
            local first = (page - 1) * book_perpage + 1
            local last = math.min(total_books, first + book_perpage - 1)
            if last >= first then
                if ok_UIManager then
                    UIManager:scheduleIn(0, function()
                        pcall(self.on_page_changed, page, first, last, self)
                    end)
                end
            end
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

    -- 翻到下一页
    function ShelfMenu:onNextPage()
        local perpage = self.perpage or 7
        -- 重新计算 action_area_count
        local action_area_count = 0
        for i = 1, #self.item_table do
            local entry = self.item_table[i]
            if entry.separator or entry._miu_action_row then
                action_area_count = action_area_count + 1
            else
                break
            end
        end
        local action_area_end = action_area_count
        local book_perpage = perpage - action_area_count
        if book_perpage < 1 then book_perpage = 1 end
        local total_books = #self.item_table - action_area_end
        local total_pages = math.ceil(total_books / book_perpage)
        if total_pages < 1 then total_pages = 1 end

        self.page = (self.page or 1) + 1
        if self.page > total_pages then self.page = total_pages end
        self:updateItems(1)
        return true
    end

    -- 翻到上一页
    function ShelfMenu:onPrevPage()
        self.page = (self.page or 1) - 1
        if self.page < 1 then self.page = 1 end
        self:updateItems(1)
        return true
    end

    -- 跳转到指定页
    function ShelfMenu:gotoPage(page)
        self.page = tonumber(page) or 1
        if self.page < 1 then self.page = 1 end
        self:updateItems(1)
        return true
    end
end

local ShelfView = {}
ShelfView.__index = ShelfView

function ShelfView:new(plugin)
    local obj = {
        plugin = plugin,
        book_list_menu = nil,
        current_series_id = nil,
    }
    return setmetatable(obj, self)
end

local function format_update_time(ts)
    ts = tonumber(ts) or 0
    if ts == 0 then return "" end
    local now = os.time()
    local diff = now - ts
    if diff < 0 then diff = 0 end
    if diff < 60 then return _("刚刚") end
    if diff < 3600 then return string.format(_("%d分钟前"), math.floor(diff / 60)) end
    if diff < 86400 then return string.format(_("%d小时前"), math.floor(diff / 3600)) end
    if diff < 86400 * 7 then return string.format(_("%d天前"), math.floor(diff / 86400)) end
    return os.date("%Y-%m-%d", ts)
end

function ShelfView:show(series_id_opt, skip_refresh)
    if not (ok_UIManager and ok_Menu) then
        Log.error("ShelfView:show UIManager 或 Menu 不可用")
        return
    end

    local plugin = self.plugin
    local settings = plugin and plugin.settings
    local bookshelf = plugin and plugin.bookshelf

    if not settings or not bookshelf then
        Log.error("ShelfView:show plugin 缺少 settings/bookshelf")
        return
    end

    local uin = settings:get_uin()
    local cookie = settings:get_cookie()
    if uin == "" or cookie == "" then
        if ok_InfoMessage then
            UIManager:show(InfoMessage:new{
                text = _("未登录，请先在 Koobone 设置中登录"),
                timeout = 3,
            })
        end
        return
    end

    self:close()

    self.current_series_id = series_id_opt
    local is_vol_view = series_id_opt ~= nil and series_id_opt ~= ""

    local items = {}

    -- 顶部操作区（不加分隔符）
    if not is_vol_view then
        -- 系列列表层：刷新书架 + 排序
        local current_sort = settings:get_shelf_sort()
        local sort_label_map = {
            uptime = _("按更新时间"),
            vol_name = _("按名称"),
            last_read = _("按最后阅读"),
        }
        items[#items + 1] = {
            _miu_action_row = true,
            action_text = _("排序: ") .. (sort_label_map[current_sort] or current_sort),
            callback = function()
                self:_show_sort_dialog()
            end,
        }
        items[#items + 1] = {
            _miu_action_row = true,
            action_text = _("⟳ 刷新书架"),
            callback = function()
                self:_refresh_shelf()
            end,
        }
    else
        -- 卷列表层：返回系列列表 + 排序
        local current_sort = settings:get_shelf_sort()
        local sort_label_map = {
            uptime = _("按更新时间"),
            vol_name = _("按名称"),
            last_read = _("按最后阅读"),
        }
        items[#items + 1] = {
            _miu_action_row = true,
            action_text = _("排序: ") .. (sort_label_map[current_sort] or current_sort),
            callback = function()
                self:_show_sort_dialog()
            end,
        }
        items[#items + 1] = {
            _miu_action_row = true,
            action_text = _("⟵ 返回系列列表"),
            callback = function()
                self:show(nil)
            end,
        }
    end

    local self_ref = self
    local menu_title

    if not is_vol_view then
        -- ========== 第一级：系列列表 ==========
        local series_list = bookshelf:get_series_list()

        if not series_list or #series_list == 0 then
            if ok_InfoMessage then
                UIManager:show(InfoMessage:new{
                    text = _("书架为空\n请检查网络或登录状态"),
                    timeout = 3,
                })
            end
            return
        end

        for _idx, series in ipairs(series_list) do
            -- 系列封面：用伪 vol 结构下载，key 为 series_<id> 避免和卷封面冲突
            local cover_path = nil
            if settings:should_download_covers() and series.cover_url and series.cover_url ~= "" then
                local pseudo_vol = {
                    file_md5 = "series_" .. tostring(series.id),
                    cover_url = series.cover_url,
                }
                local ok_cover, cp = pcall(function()
                    return bookshelf:get_cover_local_path(pseudo_vol)
                end)
                if ok_cover then cover_path = cp end
            end

            local update_str = format_update_time(series.last_update_time)
            local vol_count_str = string.format(_("%d 卷"), series.vol_count or 0)

            -- 拼副信息行：作者 · 卷数 · 更新时间
            local sub_parts = {}
            if series.author and series.author ~= "" then
                sub_parts[#sub_parts + 1] = series.author
            end
            sub_parts[#sub_parts + 1] = vol_count_str
            if update_str ~= "" then
                sub_parts[#sub_parts + 1] = update_str
            end

            items[#items + 1] = {
                title = series.title or _("未命名系列"),
                author = table.concat(sub_parts, " · "),
                series = "",
                status = "",
                cover_path = cover_path,
                show_cover = cover_path ~= nil,
                callback = function()
                    self_ref:show(series.id)
                end,
                hold_callback = function()
                    self_ref:_show_series_action_dialog(series)
                end,
            }
        end

        menu_title = _("Koobone 书架")
    else
        -- ========== 第二级：系列详情（卷列表）==========
        local display_vols = bookshelf:get_series_vols(series_id_opt)

        if not display_vols or #display_vols == 0 then
            if ok_InfoMessage then
                UIManager:show(InfoMessage:new{
                    text = _("该系列无卷\n请检查网络或返回书架"),
                    timeout = 3,
                })
            end
            return
        end

        for _idx, vol in ipairs(display_vols) do
            local cover_path = nil
            local ok_cover, cp = pcall(function()
                return bookshelf:get_cover_local_path(vol)
            end)
            if ok_cover then
                cover_path = cp
            end

            local status_text
            local ok_status, st = pcall(function()
                return bookshelf:get_progress_text(vol)
            end)
            if ok_status then
                status_text = st
            else
                status_text = _("未开始")
            end

            local downloaded = bookshelf:is_vol_downloaded(vol)
            if downloaded then
                if status_text and status_text ~= "" then
                    status_text = _("已缓存") .. " · " .. status_text
                else
                    status_text = _("已缓存")
                end
            end

            items[#items + 1] = {
                fmd = vol.file_md5 or vol.fmd,
                vol = vol,
                title = vol.title or _("未命名"),
                author = vol.author or "",
                series = vol.series or "",
                status = status_text,
                cover_path = cover_path,
                show_cover = cover_path ~= nil,
                callback = function()
                    self_ref:_show_vol_action_dialog(vol)
                end,
                hold_callback = function()
                    self_ref:_show_vol_action_dialog(vol)
                end,
            }
        end

        -- 从卷列表中取系列名做标题（避免重复调用 get_series_list）
        local series_title = ""
        if display_vols and display_vols[1] then
            series_title = display_vols[1].series or ""
        end
        menu_title = series_title ~= "" and series_title or _("系列详情")
    end

    -- 计算操作行数量（不计入分页）
    local action_count = 0
    for _, item in ipairs(items) do
        if item._miu_action_row then
            action_count = action_count + 1
        end
    end

    local menu = ShelfMenu:new{
        title = menu_title,
        item_table = items,
        items_per_page = 7,
        _action_count = action_count,
        is_borderless = true,
        title_bar_fm_style = true,
        on_close_callback = function()
            self.book_list_menu = nil
        end,
    }

    self.book_list_menu = menu
    UIManager:show(menu)
end

function ShelfView:_show_series_action_dialog(series)
    if not (ok_UIManager and ok_ButtonDialog) then return end
    local self_ref = self
    local vol_count = series.vol_count or 0
    local info_lines = {
        _("系列: ") .. (series.title or ""),
        _("作者: ") .. (series.author or _("未知")),
        _("卷数: ") .. tostring(vol_count),
        _("更新: ") .. format_update_time(series.last_update_time),
    }
    local buttons = {
        {
            {
                text = _("查看详情"),
                callback = function()
                    if ok_InfoMessage then
                        UIManager:show(InfoMessage:new{
                            text = table.concat(info_lines, "\n"),
                            timeout = 5,
                        })
                    end
                end,
            },
            {
                text = _("进入系列"),
                callback = function()
                    self_ref:show(series.id)
                end,
            },
        },
        {
            {
                text = _("下载本系列全部"),
                callback = function()
                    UIManager:close(self_ref._action_dialog)
                    self_ref._action_dialog = nil
                    self_ref:_download_series_all(series)
                end,
            },
        },
    }
    self._action_dialog = ButtonDialog:new{
        title = _("系列操作"),
        buttons = buttons,
    }
    UIManager:show(self._action_dialog)
end

function ShelfView:_show_sort_dialog()
    if not (ok_UIManager and ok_ButtonDialog) then return end
    local self_ref = self
    local function choose(sort_key)
        if self_ref._sort_dialog then
            pcall(function() UIManager:close(self_ref._sort_dialog) end)
            self_ref._sort_dialog = nil
        end
        self_ref:update_sort(sort_key)
    end
    local buttons = {
        {
            {
                text = _("按更新时间"),
                callback = function() choose("uptime") end,
            },
            {
                text = _("按名称"),
                callback = function() choose("vol_name") end,
            },
        },
        {
            {
                text = _("按最后阅读"),
                callback = function() choose("last_read") end,
            },
        },
    }
    self._sort_dialog = ButtonDialog:new{
        title = _("选择排序方式"),
        buttons = buttons,
    }
    UIManager:show(self._sort_dialog)
end

function ShelfView:_refresh_shelf()
    if not ok_UIManager then return end
    local plugin = self.plugin
    local bookshelf = plugin and plugin.bookshelf
    if not bookshelf then return end

    local info
    if ok_InfoMessage then
        info = InfoMessage:new{ text = _("正在刷新书架...") }
        UIManager:show(info)
    end

    UIManager:scheduleIn(0.01, function()
        local ok, result, err = pcall(function()
            return bookshelf:refresh(true)
        end)
        if info and ok_InfoMessage then
            UIManager:close(info)
        end
        if ok and result then
            if ok_InfoMessage then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("刷新成功，共 %d 卷"), #result),
                    timeout = 2,
                })
            end
            -- 刷新成功后，重置初始化标志，下次打开书架时会重新检查登录状态
            if plugin then
                plugin._shelf_initialized = false
            end
            self:show(self.current_series_id, true)
        else
            local err_msg = tostring(err or result or _("未知错误"))
            if ok_InfoMessage then
                UIManager:show(InfoMessage:new{
                    text = _("刷新失败: ") .. err_msg,
                    timeout = 3,
                })
            end
        end
    end)
end

function ShelfView:_show_vol_action_dialog(vol)
    if not (ok_UIManager and ok_ButtonDialog) then return end
    if not vol then return end

    local plugin = self.plugin
    local bookshelf = plugin and plugin.bookshelf
    local self_ref = self
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    local downloaded = false
    if bookshelf then
        downloaded = bookshelf:is_vol_downloaded(vol)
    end

    local buttons = {}

    -- 第一行: 主要操作 (根据下载状态显示)
    local row1 = {}
    if downloaded then
        table.insert(row1, {
            text = _("开始阅读"),
            callback = function()
                UIManager:close(self_ref._action_dialog)
                self_ref._action_dialog = nil
                if plugin and plugin.open_comic then
                    -- 用 xpcall 捕获错误并记录日志，避免静默失败
                    local ok_open, err = xpcall(function()
                        plugin:open_comic(vol)
                    end, function(e)
                        return tostring(e) .. "\n" .. debug.traceback("", 2)
                    end)
                    if not ok_open then
                        Log.error("[ShelfView] open_comic 失败: " .. tostring(err))
                        if ok_InfoMessage then
                            UIManager:show(InfoMessage:new{
                                text = _("打开失败: ") .. tostring(err),
                                timeout = 5,
                            })
                        end
                    end
                else
                    Log.error("[ShelfView] plugin 或 plugin.open_comic 为空")
                    if ok_InfoMessage then
                        UIManager:show(InfoMessage:new{ text = _("阅读器未就绪"), timeout = 3 })
                    end
                end
            end,
        })
        table.insert(row1, {
            text = _("重新下载"),
            callback = function()
                UIManager:close(self_ref._action_dialog)
                self_ref._action_dialog = nil
                if plugin and plugin.download_comic then
                    pcall(function()
                        plugin:download_comic(vol, true)
                    end)
                end
            end,
        })
    else
        table.insert(row1, {
            text = _("下载书籍"),
            callback = function()
                UIManager:close(self_ref._action_dialog)
                self_ref._action_dialog = nil
                if plugin and plugin.download_comic then
                    pcall(function()
                        plugin:download_comic(vol)
                    end)
                end
            end,
        })
    end
    table.insert(buttons, row1)

    -- 第二行: 信息和管理操作
    table.insert(buttons, {
        {
            text = _("卷信息"),
            callback = function()
                UIManager:close(self_ref._action_dialog)
                self_ref._action_dialog = nil
                self_ref:_show_vol_info(vol)
            end,
        },
        {
            text = _("删除缓存"),
            callback = function()
                UIManager:close(self_ref._action_dialog)
                self_ref._action_dialog = nil
                self_ref:_delete_vol_cache(vol)
            end,
        },
    })

    self._action_dialog = ButtonDialog:new{
        title = vol.title or _("卷操作"),
        buttons = buttons,
    }
    UIManager:show(self._action_dialog)
end

function ShelfView:_show_vol_info(vol)
    if not (ok_UIManager and ok_InfoMessage) then return end
    local lines = {}
    table.insert(lines, _("标题: ") .. (vol.title or ""))
    table.insert(lines, _("作者: ") .. (vol.author or ""))
    table.insert(lines, _("系列: ") .. (vol.series or ""))
    table.insert(lines, _("卷序号: ") .. tostring(vol.vol_snumber or "-"))
    table.insert(lines, _("总页数: ") .. tostring(vol.total_pages or 0))
    table.insert(lines, _("已读页: ") .. tostring(vol.last_readpage or 0))
    local plugin = self.plugin
    local bookshelf = plugin and plugin.bookshelf
    if bookshelf then
        local prog = bookshelf:get_progress_text(vol)
        local downloaded = bookshelf:is_vol_downloaded(vol) and _("是") or _("否")
        table.insert(lines, _("阅读进度: ") .. prog)
        table.insert(lines, _("已缓存: ") .. downloaded)
    end
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd ~= "" then
        table.insert(lines, "FMD: " .. fmd:sub(1, 16) .. "...")
    end
    if vol.update_time and vol.update_time > 0 then
        table.insert(lines, _("更新时间: ") .. os.date("%Y-%m-%d", vol.update_time))
    end
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
        timeout = 5,
    })
end

function ShelfView:_delete_vol_cache(vol)
    if not (ok_UIManager and ok_ConfirmBox) then return end
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return end
    local epub_dir = H.join_path(H.get_epub_dir(), fmd)
    local title = vol.title or ""
    UIManager:show(ConfirmBox:new{
        text = string.format(_("确定要删除《%s》的本地缓存吗？"), title),
        ok_text = _("删除"),
        cancel_text = _("取消"),
        ok_callback = function()
            if H.dir_exists(epub_dir) then
                H.delete_dir(epub_dir)
            end
            if ok_InfoMessage then
                UIManager:show(InfoMessage:new{
                    text = _("缓存已删除"),
                    timeout = 2,
                })
            end
        end,
    })
end

function ShelfView:_clear_vol_progress(vol)
    if not (ok_UIManager and ok_ConfirmBox) then return end
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return end
    local plugin = self.plugin
    local bookshelf = plugin and plugin.bookshelf
    if not bookshelf then return end
    local title = vol.title or ""
    UIManager:show(ConfirmBox:new{
        text = string.format(_("确定要清除《%s》的阅读进度吗？"), title),
        ok_text = _("清除"),
        cancel_text = _("取消"),
        ok_callback = function()
            local v = bookshelf:get_vol_by_fmd(fmd)
            if v then
                v.last_readpage = 0
                if ok_InfoMessage then
                    UIManager:show(InfoMessage:new{
                        text = _("进度已清除"),
                        timeout = 2,
                    })
                end
                self:show(self.current_series_id)
            end
        end,
    })
end

function ShelfView:update_sort(new_sort)
    local plugin = self.plugin
    local bookshelf = plugin and plugin.bookshelf
    if bookshelf then
        bookshelf:sort_vols(new_sort)
    end
    self:show(self.current_series_id)
end

function ShelfView:refresh_current()
    -- 重新显示当前视图（系列列表或卷列表），以反映最新的下载状态
    -- 使用 skip_refresh=true 避免触发网络请求，仅更新本地 UI
    if self.current_series_id then
        self:show(self.current_series_id, true)
    end
end

function ShelfView:close()
    if self.book_list_menu and ok_UIManager then
        UIManager:close(self.book_list_menu)
        self.book_list_menu = nil
    end
end

-- 下载本系列全部（使用队列机制，避免并发）
function ShelfView:_download_series_all(series)
    if not (ok_UIManager and ok_InfoMessage) then return end
    local plugin = self.plugin
    local bookshelf = plugin and plugin.bookshelf
    local download = plugin and plugin.download
    
    if not download or not bookshelf then
        UIManager:show(InfoMessage:new{
            text = _("下载模块未就绪"),
            timeout = 3,
        })
        return
    end
    
    local series_id = tostring(series.id or "")
    if series_id == "" then return end
    
    local vols = bookshelf:get_series_vols(series_id)
    if not vols or #vols == 0 then
        UIManager:show(InfoMessage:new{
            text = _("该系列无卷可下载"),
            timeout = 3,
        })
        return
    end
    
    -- 过滤掉已下载的卷
    local to_download = {}
    for _, vol in ipairs(vols) do
        if not download:is_downloaded(vol) then
            table.insert(to_download, vol)
        end
    end
    
    if #to_download == 0 then
        UIManager:show(InfoMessage:new{
            text = _("该系列已全部下载完成"),
            timeout = 3,
        })
        return
    end
    
    -- 订阅队列状态变化，更新 UI 提示
    local listener_id = "series_download_" .. tostring(series_id)
    download:subscribe_queue(listener_id, function(status)
        if status and status.total > 0 then
            local msg = string.format(_("下载队列: %d/%d"), status.total - status.queued - status.active, status.total)
            if ok_InfoMessage then
                -- 避免频繁刷新，只在关键状态变化时提示
                if not self._last_queue_msg or self._last_queue_msg ~= msg then
                    self._last_queue_msg = msg
                    UIManager:show(InfoMessage:new{
                        text = msg,
                        timeout = 2,
                    })
                end
            end
        end
    end)
    
    -- 添加到下载队列
    local added, skipped = download:enqueue_batch(to_download, {
        on_success = function(vol, epub_path)
            Log.info("[ShelfView] 批量下载成功: " .. tostring(vol.title or vol.fmd))
        end,
        on_fail = function(vol, err)
            Log.warn("[ShelfView] 批量下载失败: " .. tostring(vol.title or vol.fmd) .. " err=" .. tostring(err))
        end,
    })
    
    -- 显示结果
    local msg = string.format(_("已将 %d 卷加入下载队列"), added)
    if skipped > 0 then
        msg = msg .. string.format(_("，跳过 %d 卷(已下载)"), skipped)
    end
    
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 3,
    })
    
    -- 30 秒后取消订阅（避免内存泄漏）
    UIManager:scheduleIn(30, function()
        download:unsubscribe_queue(listener_id)
    end)
end

return ShelfView
