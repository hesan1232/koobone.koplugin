local H = require("koobone.helper")
local Log = require("koobone.logger")
local _state = require("koobone.state")
local Async = require("koobone.async")

local ok_Blitbuffer, Blitbuffer = pcall(require, "ffi/blitbuffer")
local ok_Device, Device = pcall(require, "device")
local ok_Font, Font = pcall(require, "ui/font")
local ok_Geom, Geom = pcall(require, "ui/geometry")
local ok_GestureRange, GestureRange = pcall(require, "ui/gesturerange")
local ok_HorizontalGroup, HorizontalGroup = pcall(require, "ui/widget/horizontalgroup")
local ok_HorizontalSpan, HorizontalSpan = pcall(require, "ui/widget/horizontalspan")
local ok_VerticalGroup, VerticalGroup = pcall(require, "ui/widget/verticalgroup")
local ok_VerticalSpan, VerticalSpan = pcall(require, "ui/widget/verticalspan")
local ok_InputContainer, InputContainer = pcall(require, "ui/widget/container/inputcontainer")
local ok_WidgetContainer, WidgetContainer = pcall(require, "ui/widget/container/widgetcontainer")
local ok_LeftContainer, LeftContainer = pcall(require, "ui/widget/container/leftcontainer")
local ok_RightContainer, RightContainer = pcall(require, "ui/widget/container/rightcontainer")
local ok_CenterContainer, CenterContainer = pcall(require, "ui/widget/container/centercontainer")
local ok_OverlapGroup, OverlapGroup = pcall(require, "ui/widget/overlapgroup")
local ok_ImageWidget, ImageWidget = pcall(require, "ui/widget/imagewidget")
local ok_TextWidget, TextWidget = pcall(require, "ui/widget/textwidget")
local ok_TextBoxWidget, TextBoxWidget = pcall(require, "ui/widget/textboxwidget")
local ok_Button, Button = pcall(require, "ui/widget/button")
local ok_ProgressWidget, ProgressWidget = pcall(require, "ui/widget/progresswidget")
local ok_Size, Size = pcall(require, "ui/size")
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_InfoMessage, InfoMessage = pcall(require, "ui/widget/infomessage")
local ok_ConfirmBox, ConfirmBox = pcall(require, "ui/widget/confirmbox")
local ok_InputDialog, InputDialog = pcall(require, "ui/widget/inputdialog")
local ok_TextViewer, TextViewer = pcall(require, "ui/widget/textviewer")
local ok_ButtonDialog, ButtonDialog = pcall(require, "ui/widget/buttondialog")
local ok_gettext, gettext = pcall(require, "gettext")

-- Screen 从 Device 获取
local Screen = ok_Device and Device and Device.screen or nil

local Progress = require("koobone.progress")

local _ = ok_gettext and gettext or function(s) return s end

local Reader = {}
Reader.__index = Reader

function Reader:new(plugin)
    local obj = {
        plugin = plugin,
        settings = plugin and plugin.settings,
        bookshelf = plugin and plugin.bookshelf,
        client = plugin and plugin.client,
        download = plugin and plugin.download,
        auth = plugin and plugin.auth,
        shelf_view = plugin and plugin.shelf_view,

        _current_vol = nil,
        _pages = {},
        _extract_dir = nil,
        _page_index = 0,
        _total_pages = 0,
        _progress = nil,
        _menu_visible = false,
        _menu_auto_hide_handle = nil,
        _widget = nil,
        _preloading = false,
        _image_widget = nil,
        _top_menu = nil,
        _bottom_menu = nil,
        _overlay_mask = nil,
        _progress_widget = nil,
        _page_text_widget = nil,
        _night_mode = false,
        _last_preload_msg = "",
        _preload_msg_handle = nil,
    }
    -- 注册预下载进度回调（在构造函数中设置，使其能够访问 self）
    obj._on_preload_progress = function(msg)
        local self_ref = obj
        if self_ref._preload_msg_handle then
            -- 取消之前的定时任务
            local ok_tm, tm = pcall(require, "ui/time")
            if ok_tm and tm and tm.removeSchedulerItem then
                tm.removeSchedulerItem(self_ref._preload_msg_handle)
            end
        end
        -- 显示提示信息
        _show_info(msg)
        -- 3 秒后自动消失
        local ok_sched, sched = pcall(require, "scheduler")
        if ok_sched and sched then
            self_ref._preload_msg_handle = sched.schedule(function()
                self_ref._preload_msg_handle = nil
            end, 3)
        end
    end
    return setmetatable(obj, self)
end

local function _show_info(text)
    if ok_UIManager and UIManager and ok_InfoMessage and InfoMessage then
        UIManager:show(InfoMessage:new{ text = text })
    else
        Log.info("[Reader][Info]", text)
    end
end

local function _confirm(title, text, ok_cb, cancel_cb)
    if ok_UIManager and UIManager and ok_ConfirmBox and ConfirmBox then
        UIManager:show(ConfirmBox:new{
            text = text,
            ok_text = _("确定"),
            cancel_text = _("取消"),
            ok_callback = function()
                if ok_cb then ok_cb() end
            end,
            cancel_callback = function()
                if cancel_cb then cancel_cb() end
            end,
        })
    else
        if ok_cb then ok_cb() end
    end
end

function Reader:_screen_size()
    if Screen then
        return Screen:getWidth(), Screen:getHeight()
    end
    return 600, 800
end

function Reader:_get_menu_height()
    return 60
end

function Reader:open_comic(vol_or_fmd)
    local vol
    if type(vol_or_fmd) == "string" then
        if not self.bookshelf then
            _show_info(_("书架模块未初始化"))
            return false
        end
        vol = self.bookshelf:get_vol_by_fmd(vol_or_fmd)
        if not vol then
            _show_info(_("未找到该漫画"))
            return false
        end
    elseif type(vol_or_fmd) == "table" then
        vol = vol_or_fmd
    else
        _show_info(_("参数错误"))
        return false
    end

    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then
        _show_info(_("漫画标识无效"))
        return false
    end

    -- 修复: 初始化预下载所需属性
    self._bookshelf = self.bookshelf
    self._current_series_id = tostring(vol.series_id or vol.series or "")
    self._current_vol = vol

    local needs_download = true
    if self.download and self.bookshelf then
        needs_download = not self.bookshelf:is_vol_downloaded(vol)
    end

    if needs_download then
        if not self.download then
            _show_info(_("下载模块未初始化"))
            return false
        end
        _show_info(_("开始下载: ") .. tostring(vol.title or fmd))
        local reader_self = self
        local download_vol = vol

        -- 用 Async.run 在子进程中下载，不卡 UI
        Async.run(
            function()
                -- 子进程中执行: 下载 + 解压 + 解析
                -- 注意: 子进程中不能访问主进程的 _state/UIManager，所以不传 progress_callback
                local ok_pcall, v, pages, edir, err = pcall(function()
                    return reader_self.download:ensure_epub(download_vol, nil)
                end)
                if ok_pcall and pages and not err then
                    return { ok = true, vol = v or download_vol, pages = pages, edir = edir }
                else
                    return { ok = false, err = tostring(err or (not ok_pcall and pages or "unknown")) }
                end
            end,
            function(ok_run, result, err_run)
                -- 主进程中回调: 更新 UI
                if not ok_run then
                    _show_info(_("下载失败: ") .. tostring(err_run))
                    return
                end
                if not result then
                    _show_info(_("下载失败: 无返回值"))
                    return
                end
                if result.ok then
                    reader_self:_after_download(result.vol or download_vol, result.pages, result.edir)
                else
                    _show_info(_("下载失败: ") .. tostring(result.err or "unknown"))
                end
            end,
            { timeout = 300 }  -- 5 分钟超时
        )
        return true
    else
        local pages = nil
        local edir = nil
        if self.download then
            pages = self.download:get_pages(fmd)
            local fmd_key = tostring(vol.file_md5 or fmd)
            local epub_dir = H.join_path(H.get_epub_dir(), fmd_key)
            edir = epub_dir
            if not pages or #pages == 0 then
                local ok_ensure, v2, p2, e2, err2 = pcall(function()
                    return self.download:ensure_epub(vol, nil)
                end)
                if ok_ensure and p2 then
                    pages = p2
                    edir = e2
                end
            end
        end
        if not pages or #pages == 0 then
            _show_info(_("无法获取页面信息"))
            return false
        end
        self:_after_download(vol, pages, edir)
        return true
    end
end

function Reader:_after_download(vol, pages, extract_dir)
    self._current_vol = vol
    self._pages = pages or {}
    self._extract_dir = extract_dir
    self._total_pages = #(self._pages or {})

    local fmd = tostring(vol.file_md5 or vol.fmd or "")

    local start_page = 0
    local vol_last = tonumber(vol.last_readpage) or 0
    if vol_last >= 1 then
        start_page = vol_last - 1
    elseif vol_last > 0 then
        start_page = vol_last
    end
    if start_page < 0 then start_page = 0 end
    if self._total_pages > 0 and start_page >= self._total_pages then
        start_page = self._total_pages - 1
    end
    self._page_index = start_page

    if self.settings and self.client and self.bookshelf then
        local progress = Progress:new(self.settings, self.client, self.bookshelf)
        local pulled_cb = function(cloud_page_1based, total_pages, vol_info)
            if self._current_vol and tostring(self._current_vol.file_md5 or self._current_vol.fmd) ~= fmd then
                return
            end
            local cloud_0based = cloud_page_1based - 1
            if cloud_0based < 0 then cloud_0based = 0 end
            if self._total_pages > 0 and cloud_0based >= self._total_pages then
                cloud_0based = self._total_pages - 1
            end
            if cloud_0based > self._page_index then
                local msg = string.format(_("云端进度更新（%d/%d页），是否跳转？"),
                    cloud_page_1based, total_pages or self._total_pages)
                _confirm(_("进度同步"), msg, function()
                    self:_goto_page(cloud_0based)
                end)
            end
        end
        progress:start_session(fmd, self._page_index, self._total_pages, pulled_cb)
        self._progress = progress
    end

    local series = tostring(vol.series or "")
    local title = tostring(vol.title or fmd)
    _state.setCurrentComic({
        fmd = fmd,
        title = title,
        series = series,
        total_pages = self._total_pages,
    })

    self:_show_reader_widget()
    return true
end

function Reader:_build_top_menu()
    local screen_w = self:_screen_size()
    local height = self:_get_menu_height()

    if not (ok_HorizontalGroup and ok_TextWidget and ok_Button) then
        return nil
    end

    local vol = self._current_vol or {}
    local title = tostring(vol.title or "")
    local series = tostring(vol.series or "")
    local display_title = title
    if series ~= "" and series ~= title then
        display_title = series .. " - " .. title
    end

    local back_btn
    if ok_Button then
        back_btn = Button:new{
            text = "←",
            margin = 4,
            bordersize = 0,
            callback = function()
                self:close_reader(true)
            end,
        }
    end

    local title_widget
    if ok_TextWidget and ok_Font then
        local face
        pcall(function() face = Font:getFace("cfont", 20) end)
        if face then
            local max_w = screen_w - 160
            title_widget = TextWidget:new{
                text = display_title,
                face = face,
                bold = true,
                max_width = max_w,
            }
        else
            title_widget = TextWidget:new{
                text = display_title,
                bold = true,
            }
        end
    end

    local info_btn
    if ok_Button then
        info_btn = Button:new{
            text = "ℹ",
            margin = 4,
            bordersize = 0,
            callback = function()
                self:_show_book_info()
            end,
        }
    end

    local group = HorizontalGroup:new()
    if back_btn then table.insert(group, back_btn) end
    if ok_HorizontalSpan then table.insert(group, HorizontalSpan:new{ width = 8 }) end
    if ok_CenterContainer and title_widget then
        table.insert(group, CenterContainer:new{
            dimen = Geom and Geom:new{ w = screen_w - 200, h = height } or nil,
            title_widget,
        })
    elseif title_widget then
        table.insert(group, title_widget)
    end
    if ok_HorizontalSpan then table.insert(group, HorizontalSpan:new{ width = 8 }) end
    if info_btn then table.insert(group, info_btn) end

    return group
end

function Reader:_build_bottom_menu()
    local screen_w, _ = self:_screen_size()

    if not (ok_VerticalGroup and ok_HorizontalGroup and ok_ProgressWidget and ok_Button) then
        return nil
    end

    local row1 = HorizontalGroup:new()

    local prev_vol_btn
    if ok_Button then
        prev_vol_btn = Button:new{
            text = "⟵",
            margin = 4,
            bordersize = 0,
            show_parent = self._widget,
            callback = function()
                self:_prev_vol()
            end,
        }
    end

    local progress_row = HorizontalGroup:new()
    self._progress_widget = nil
    if ok_ProgressWidget then
        self._progress_widget = ProgressWidget:new{
            width = math.max(100, screen_w - 240),
            height = 20,
            percentage = self._total_pages > 0 and (self._page_index / self._total_pages) or 0,
            margin = 2,
        }
    end

    local page_text = string.format("%d / %d",
        self._total_pages > 0 and (self._page_index + 1) or 0,
        self._total_pages)
    self._page_text_widget = nil
    if ok_TextWidget and ok_Font then
        local face
        pcall(function() face = Font:getFace("cfont", 16) end)
        self._page_text_widget = TextWidget:new{
            text = page_text,
            face = face,
        }
    end

    local next_vol_btn
    if ok_Button then
        next_vol_btn = Button:new{
            text = "⟶",
            margin = 4,
            bordersize = 0,
            show_parent = self._widget,
            callback = function()
                self:_next_vol()
            end,
        }
    end

    if prev_vol_btn then table.insert(row1, prev_vol_btn) end
    if ok_HorizontalSpan then table.insert(row1, HorizontalSpan:new{ width = 4 }) end
    if self._progress_widget then table.insert(row1, self._progress_widget) end
    if ok_HorizontalSpan then table.insert(row1, HorizontalSpan:new{ width = 4 }) end
    if self._page_text_widget then table.insert(row1, self._page_text_widget) end
    if ok_HorizontalSpan then table.insert(row1, HorizontalSpan:new{ width = 4 }) end
    if next_vol_btn then table.insert(row1, next_vol_btn) end

    local row2 = HorizontalGroup:new()
    local display_btn, cache_btn, sync_btn, exit_btn
    if ok_Button then
        display_btn = Button:new{
            text = _("显示"),
            margin = 2,
            bordersize = 1,
            show_parent = self._widget,
            callback = function()
                self:_toggle_night_mode()
            end,
        }
        cache_btn = Button:new{
            text = _("缓存"),
            margin = 2,
            bordersize = 1,
            show_parent = self._widget,
            callback = function()
                _show_info(_("已整本缓存"))
            end,
        }
        sync_btn = Button:new{
            text = _("进度"),
            margin = 2,
            bordersize = 1,
            show_parent = self._widget,
            callback = function()
                self:_show_sync_menu()
            end,
        }
        exit_btn = Button:new{
            text = _("退出"),
            margin = 2,
            bordersize = 1,
            show_parent = self._widget,
            callback = function()
                self:close_reader(true)
            end,
        }
    end
    if display_btn then table.insert(row2, display_btn) end
    if ok_HorizontalSpan then table.insert(row2, HorizontalSpan:new{ width = 8 }) end
    if cache_btn then table.insert(row2, cache_btn) end
    if ok_HorizontalSpan then table.insert(row2, HorizontalSpan:new{ width = 8 }) end
    if sync_btn then table.insert(row2, sync_btn) end
    if ok_HorizontalSpan then table.insert(row2, HorizontalSpan:new{ width = 8 }) end
    if exit_btn then table.insert(row2, exit_btn) end

    local bottom = VerticalGroup:new()
    table.insert(bottom, row1)
    if ok_VerticalSpan then table.insert(bottom, VerticalSpan:new{ width = 4 }) end
    table.insert(bottom, row2)

    return bottom
end

function Reader:_show_reader_widget()
    if not (ok_InputContainer and ok_UIManager and UIManager) then
        _show_info(_("UI组件不可用，阅读器无法启动"))
        return
    end

    local screen_w, screen_h = self:_screen_size()
    local menu_h = self:_get_menu_height()

    self._top_menu = self:_build_top_menu()
    self._bottom_menu = self:_build_bottom_menu()

    self._image_widget = self:_build_image_widget()

    local container = InputContainer:new{
        dimen = Geom and Geom:new{ w = screen_w, h = screen_h } or nil,
    }

    if ok_GestureRange and GestureRange then
        container.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = Geom and Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h } } },
            Swipe = { GestureRange:new{ ges = "swipe", range = Geom and Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h } } },
        }
    end

    container.key_events = {
        Back = { { "Back" } },
        LPgBack = { { "LPgBack" } },
        RPgBack = { { "RPgBack" } },
        LPgFwd = { { "LPgFwd" } },
        RPgFwd = { { "RPgFwd" } },
        PageUp = { { "PageUp" } },
        PageDown = { { "PageDown" } },
    }

    local reader_self = self
    function container:onBack()
        reader_self:close_reader(true)
        return true
    end
    function container:onLPgBack() reader_self:_prev_page(); return true end
    function container:onRPgBack() reader_self:_prev_page(); return true end
    function container:onLPgFwd() reader_self:_next_page(); return true end
    function container:onRPgFwd() reader_self:_next_page(); return true end
    function container:onPageUp() reader_self:_prev_page(); return true end
    function container:onPageDown() reader_self:_next_page(); return true end

    function container:onTap(arg_, ges)
        if ges and ges.pos then
            local x = ges.pos.x or 0
            local edge_w = screen_w * 0.3
            if x < edge_w then
                reader_self:_prev_page()
                return true
            elseif x > screen_w - edge_w then
                reader_self:_next_page()
                return true
            end
        end
        reader_self:_toggle_menu()
        return true
    end

    function container:onSwipe(arg_, ges)
        if ges and ges.direction then
            if ges.direction == "west" or ges.direction == "left" then
                reader_self:_next_page()
                return true
            elseif ges.direction == "east" or ges.direction == "right" then
                reader_self:_prev_page()
                return true
            end
        end
        reader_self:_toggle_menu()
        return true
    end

    if ok_VerticalGroup and ok_VerticalSpan and VerticalGroup and VerticalSpan then
        local main_layout = VerticalGroup:new()
        local top_placeholder = VerticalGroup:new()
        if self._top_menu then
            table.insert(top_placeholder, self._top_menu)
        end
        table.insert(main_layout, top_placeholder)
        self._top_placeholder = top_placeholder

        local image_center = self._image_widget and CenterContainer:new{
            dimen = Geom and Geom:new{
                w = screen_w,
                h = screen_h - 2 * self:_get_menu_height(),
            } or nil,
            self._image_widget,
        } or self._image_widget
        table.insert(main_layout, image_center)

        local bottom_placeholder = VerticalGroup:new()
        if self._bottom_menu then
            table.insert(bottom_placeholder, self._bottom_menu)
        end
        table.insert(main_layout, bottom_placeholder)
        self._bottom_placeholder = bottom_placeholder
        container[1] = main_layout
        self._main_layout = main_layout
    elseif ok_OverlapGroup and OverlapGroup then
        local overlap = OverlapGroup:new{
            dimen = Geom and Geom:new{ w = screen_w, h = screen_h } or nil,
        }
        if self._image_widget then
            table.insert(overlap, self._image_widget)
        end
        container[1] = overlap
        self._overlap_group = overlap
    else
        if self._image_widget then
            container[1] = self._image_widget
        end
    end

    UIManager:show(container)
    self._widget = container

    self:_apply_menu_visibility()

    Log.info("[Reader] 阅读器已启动, pages=" .. tostring(self._total_pages))
end

function Reader:_build_image_widget()
    local screen_w, screen_h = self:_screen_size()
    local menu_h = self:_get_menu_height()
    local avail_h = screen_h - 2 * menu_h

    local img_widget = nil
    local page_path = nil
    if self._extract_dir and self._pages and self._pages[self._page_index + 1] then
        page_path = H.join_path(self._extract_dir, self._pages[self._page_index + 1])
    end

    if ok_ImageWidget and page_path and H.file_exists(page_path) then
        local opts = {
            file = page_path,
            width = screen_w,
            height = avail_h,
            alpha = false,
            discrete = true,
        }
        if ok_Device and Device and Device.screen and Device.screen.no_color then
            opts.discrete = true
        end
        local ok_w, w = pcall(function() return ImageWidget:new(opts) end)
        if ok_w then img_widget = w end
    end

    if not img_widget and ok_TextBoxWidget then
        local msg = _("页面加载中...")
        if not page_path or not H.file_exists(page_path) then
            msg = _("图片不存在: ") .. tostring(self._pages and self._pages[self._page_index + 1] or "?")
        end
        local ok_tb, tb = pcall(function()
            return TextBoxWidget:new{
                text = msg,
                width = screen_w,
                height = avail_h,
            }
        end)
        if ok_tb then img_widget = tb end
    end

    return img_widget
end

function Reader:_render_current_page()
    if not (ok_UIManager and UIManager) then return end
    local new_img = self:_build_image_widget()
    local updated = false
    if self._main_layout and ok_CenterContainer and CenterContainer then
        for i, child in ipairs(self._main_layout) do
            if child and type(child) == "table" and child[1] == self._image_widget then
                child[1] = new_img or child[1]
                self._image_widget = new_img or self._image_widget
                updated = true
                break
            end
        end
    end
    if not updated and self._overlap_group and self._image_widget then
        for i, child in ipairs(self._overlap_group) do
            if child == self._image_widget then
                self._overlap_group[i] = new_img or child
                self._image_widget = new_img or child
                updated = true
                break
            end
        end
    end
    if not updated and self._widget and self._image_widget then
        if self._widget[1] == self._image_widget then
            self._widget[1] = new_img or self._widget[1]
            self._image_widget = new_img or self._image_widget
        end
    end

    if self._progress_widget and ok_ProgressWidget then
        local pct = self._total_pages > 0 and (self._page_index / self._total_pages) or 0
        pcall(function()
            self._progress_widget:setPercentage(pct)
        end)
    end
    if self._page_text_widget and ok_TextWidget then
        local txt = string.format("%d / %d",
            self._total_pages > 0 and (self._page_index + 1) or 0,
            self._total_pages)
        pcall(function()
            self._page_text_widget:setText(txt)
        end)
    end

    UIManager:setDirty("all", "partial")

    -- 注意: 预下载逻辑已移至 main.lua 的 open_comic/_trigger_preload 中处理
    -- 这里不再触发预下载，避免每次翻页都触发

end

function Reader:_goto_page(page_idx)
    if self._total_pages <= 0 then return end
    local new_idx = tonumber(page_idx) or 0
    if new_idx < 0 then new_idx = 0 end
    if new_idx > self._total_pages - 1 then new_idx = self._total_pages - 1 end
    if new_idx == self._page_index then return end
    self._page_index = new_idx
    if self._progress then
        self._progress:update_page(self._page_index, self._total_pages)
    end
    self:_render_current_page()
end

function Reader:_next_page()
    if self._page_index < self._total_pages - 1 then
        self:_goto_page(self._page_index + 1)
    else
        _show_info(_("已到最后一页"))
    end
end

function Reader:_prev_page()
    if self._page_index > 0 then
        self:_goto_page(self._page_index - 1)
    else
        _show_info(_("已到第一页"))
    end
end

function Reader:_find_sibling_vol(direction)
    if not self._current_vol or not self.bookshelf then return nil end
    local sid = self._current_vol.series_id or self._current_vol.series or ""
    if sid == "" then return nil end
    local vols = self.bookshelf:get_series_vols(sid)
    if not vols or #vols == 0 then return nil end
    local cur_fmd = tostring(self._current_vol.file_md5 or self._current_vol.fmd or "")
    for i, v in ipairs(vols) do
        if tostring(v.file_md5 or v.fmd or "") == cur_fmd then
            if direction == "next" and i < #vols then
                return vols[i + 1]
            elseif direction == "prev" and i > 1 then
                return vols[i - 1]
            end
            break
        end
    end
    return nil
end

function Reader:_next_vol()
    local nv = self:_find_sibling_vol("next")
    if nv then
        self:close_reader(false)
        if self.plugin and self.plugin.open_comic then
            self.plugin:open_comic(nv)
        else
            self:open_comic(nv)
        end
    else
        _show_info(_("已是最后一卷"))
    end
end

function Reader:_prev_vol()
    local pv = self:_find_sibling_vol("prev")
    if pv then
        self:close_reader(false)
        if self.plugin and self.plugin.open_comic then
            self.plugin:open_comic(pv)
        else
            self:open_comic(pv)
        end
    else
        _show_info(_("已是第一卷"))
    end
end

function Reader:_stop_menu_auto_hide()
    if self._menu_auto_hide_handle and ok_UIManager and UIManager then
        pcall(function() UIManager:unschedule(self._menu_auto_hide_handle) end)
        self._menu_auto_hide_handle = nil
    end
end

function Reader:_reset_menu_auto_hide()
    self:_stop_menu_auto_hide()
    if not self._menu_visible then return end
    if ok_UIManager and UIManager then
        self._menu_auto_hide_handle = UIManager:scheduleIn(5, function()
            if self._menu_visible then
                self._menu_visible = false
                self:_apply_menu_visibility()
            end
            self._menu_auto_hide_handle = nil
        end)
    end
end

function Reader:_toggle_menu()
    self._menu_visible = not self._menu_visible
    self:_apply_menu_visibility()
    if self._menu_visible then
        self:_reset_menu_auto_hide()
    else
        self:_stop_menu_auto_hide()
    end
end

function Reader:_apply_menu_visibility()
    if not (ok_UIManager and UIManager) then return end
    local screen_w, screen_h = self:_screen_size()
    local menu_h = self:_get_menu_height()

    if not self._overlay_mask then
        if ok_WidgetContainer and WidgetContainer then
            local ok_bb, bb = pcall(function()
                local w_color = ok_Blitbuffer and Blitbuffer and Blitbuffer.COLOR_WHITE or 0
                local bb_ok, bbv
                if ok_Blitbuffer then
                    bb_ok, bbv = pcall(function()
                        return Blitbuffer.new(screen_w, screen_h, ok_Device and Device.screen and Device.screen.fb_bb or nil)
                    end)
                    if bb_ok and bbv then
                        pcall(function() bbv:fill(w_color) end)
                    end
                end
                return bbv
            end)
        end
    end

    if self._top_menu and self._top_menu.show then
        if self._menu_visible then
            pcall(function() self._top_menu:show() end)
        else
            pcall(function() self._top_menu:hide() end)
        end
    end
    if self._bottom_menu and self._bottom_menu.show then
        if self._menu_visible then
            pcall(function() self._bottom_menu:show() end)
        else
            pcall(function() self._bottom_menu:hide() end)
        end
    end

    UIManager:setDirty("all", "partial")
end

function Reader:_show_book_info()
    local vol = self._current_vol or {}
    local lines = {}
    table.insert(lines, _("书名: ") .. tostring(vol.title or "-"))
    table.insert(lines, _("系列: ") .. tostring(vol.series or "-"))
    table.insert(lines, _("作者: ") .. tostring(vol.author or "-"))
    local total = self._total_pages
    table.insert(lines, _("总页数: ") .. tostring(total))
    local fsize = tonumber(vol.file_size) or 0
    local size_str
    if fsize > 1024 * 1024 then
        size_str = string.format("%.2f MB", fsize / (1024 * 1024))
    elseif fsize > 1024 then
        size_str = string.format("%.1f KB", fsize / 1024)
    else
        size_str = tostring(fsize) .. " B"
    end
    table.insert(lines, _("大小: ") .. size_str)
    local add_ts = tonumber(vol.add_time) or 0
    local add_str = add_ts > 0 and os.date("%Y-%m-%d", add_ts) or "-"
    table.insert(lines, _("添加时间: ") .. add_str)
    local up_ts = tonumber(vol.update_time) or 0
    local up_str = up_ts > 0 and os.date("%Y-%m-%d", up_ts) or "-"
    table.insert(lines, _("更新时间: ") .. up_str)
    local progress_txt = "0%"
    if total > 0 then
        progress_txt = string.format("%d/%d (%.1f%%)",
            self._page_index + 1, total,
            (self._page_index + 1) / total * 100)
    end
    table.insert(lines, _("阅读进度: ") .. progress_txt)
    table.insert(lines, _("当前页: ") .. tostring(self._page_index + 1))

    local text = table.concat(lines, "\n")

    if ok_UIManager and UIManager and ok_TextViewer and TextViewer then
        local viewer
        pcall(function()
            viewer = TextViewer:new{
                title = _("书籍信息"),
                text = text,
            }
        end)
        if viewer then
            UIManager:show(viewer)
            return
        end
    end
    _show_info(text)
end

function Reader:_toggle_night_mode()
    self._night_mode = not self._night_mode
    if ok_Device and Device and Device.screen then
        pcall(function()
            if Device.screen.invert then
                Device.screen:invert(self._night_mode and "all" or nil)
            end
        end)
    end
    _show_info(self._night_mode and _("夜间模式: 开") or _("夜间模式: 关"))
    if ok_UIManager and UIManager then
        UIManager:setDirty("all", "full")
    end
end

function Reader:_show_sync_menu()
    if ok_UIManager and UIManager and ok_ButtonDialog and ButtonDialog then
        local dlg
        local buttons = {
            {
                {
                    text = _("拉取云端进度"),
                    callback = function()
                        UIManager:close(dlg)
                        self:_do_manual_pull()
                    end,
                },
                {
                    text = _("覆盖云端进度"),
                    callback = function()
                        UIManager:close(dlg)
                        self:_do_manual_push()
                    end,
                },
            },
        }
        dlg = ButtonDialog:new{
            title = _("进度同步"),
            buttons = buttons,
        }
        UIManager:show(dlg)
    else
        self:_do_manual_pull()
    end
end

function Reader:_do_manual_pull()
    if not self._progress then
        _show_info(_("进度同步不可用"))
        return
    end
    _show_info(_("正在拉取云端进度..."))
    self._progress:manual_pull(function(ok, cloud_page, msg, vol_info)
        if ok then
            local cp = tonumber(cloud_page) or 0
            if cp >= 1 then
                local cloud_0 = cp - 1
                if cloud_0 < 0 then cloud_0 = 0 end
                if self._total_pages > 0 and cloud_0 >= self._total_pages then
                    cloud_0 = self._total_pages - 1
                end
                if cloud_0 > self._page_index then
                    local msg_str = string.format(_("云端进度 %d/%d，是否跳转？"),
                        cp, self._total_pages)
                    _confirm(_("拉取成功"), msg_str, function()
                        self:_goto_page(cloud_0)
                    end)
                else
                    _show_info(string.format(_("云端进度 %d/%d，无需跳转"), cp, self._total_pages))
                end
            else
                _show_info(_("云端无进度记录"))
            end
        else
            _show_info(_("拉取失败: ") .. tostring(msg or "unknown"))
        end
    end)
end

function Reader:_do_manual_push()
    if not self._progress then
        _show_info(_("进度同步不可用"))
        return
    end
    _show_info(_("正在上传进度..."))
    self._progress:manual_push(function(ok, msg)
        if ok then
            _show_info(string.format(_("上传成功: 第 %d 页"), self._page_index + 1))
        else
            _show_info(_("上传失败: ") .. tostring(msg or "unknown"))
        end
    end)
end

function Reader:close_reader(confirm_unsync_opt)
    self:_stop_menu_auto_hide()

    local fmd = self._current_vol and tostring(self._current_vol.file_md5 or self._current_vol.fmd) or ""

    local unsynced = false
    if self._progress then
        unsynced = (self._progress._last_upload_page or -1) < self._page_index
    end

    local function do_close()
        if self._progress then
            local p = self._progress
            self._progress = nil
            pcall(function()
                p:end_session(function(ok, msg)
                    Log.debug("[Reader] 退出时进度上传:", ok and "ok" or "fail", msg or "")
                end)
            end)
        end

        if self._widget and ok_UIManager and UIManager then
            pcall(function() UIManager:close(self._widget) end)
            self._widget = nil
        end

        _state.setCurrentComic(nil)

        if self.shelf_view then
            pcall(function() self.shelf_view:show() end)
        end

        self._image_widget = nil
        self._top_menu = nil
        self._bottom_menu = nil
        self._overlap_group = nil
        self._main_layout = nil
        self._top_placeholder = nil
        self._bottom_placeholder = nil
        self._progress_widget = nil
        self._page_text_widget = nil
        self._current_vol = nil
        self._pages = {}
        self._extract_dir = nil
        self._page_index = 0
        self._total_pages = 0
        self._menu_visible = false
        self._overlay_mask = nil
        self._night_mode = false
        self._preloading = false

        Log.info("[Reader] 阅读器已关闭")
    end

    if confirm_unsync_opt and unsynced then
        _confirm(_("退出阅读器"),
            _("还有进度未上传，确定退出？"),
            do_close)
    else
        do_close()
    end
end

return Reader
