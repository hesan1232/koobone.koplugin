local LOG_MODULE = "[Koobone]"

local function safe_require(module_name, required)
    local ok, result = pcall(require, module_name)
    if not ok then
        if required then
            print(LOG_MODULE, "fatal: failed to load required module:", module_name, "-", result)
            return nil, false
        else
            print(LOG_MODULE, "warning: failed to load optional module:", module_name, "-", result)
            return nil, true
        end
    end
    return result, true
end

local WidgetContainer, ok = safe_require("ui/widget/container/widgetcontainer", true)
if not ok then return end

local lfs = safe_require("libs/libkoreader-lfs", true)
if not lfs then return end

local Dispatcher = safe_require("dispatcher", true)
if not Dispatcher then return end

local UIManager = safe_require("ui/uimanager", true)
if not UIManager then return end

local DataStorage = safe_require("datastorage", true)
if not DataStorage then return end

local InfoMessage = safe_require("ui/widget/infomessage", true)
if not InfoMessage then return end

local ConfirmBox = safe_require("ui/widget/confirmbox", true)
if not ConfirmBox then return end

local Menu = safe_require("ui/widget/menu", true)
if not Menu then return end

local InputDialog = safe_require("ui/widget/inputdialog", true)
if not InputDialog then return end

local TextViewer = safe_require("ui/widget/textviewer")

local Event = safe_require("ui/event")

local GestureRange = safe_require("ui/gesturerange")

local Geom = safe_require("ui/geometry")

local Device = safe_require("device")
local Screen = Device and Device.screen

local logger = safe_require("logger")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local T_util = safe_require("ffi/util", true)
local T = T_util and T_util.template or function(str, ...) return str end

local util = safe_require("util", true)
if not util then return end

local Settings = safe_require("koobone.settings", true)
if not Settings then return end

local Client = safe_require("koobone.client", true)
if not Client then return end

local Auth = safe_require("koobone.auth", true)
if not Auth then return end

local Cookie = safe_require("koobone.cookie", true)
if not Cookie then return end

local H = safe_require("koobone.helper", true)
if not H then return end

local Log = safe_require("koobone.logger", true)
if not Log then return end

local State = safe_require("koobone.state", true)
if not State then return end

local Async = safe_require("koobone.async", true)
if not Async then return end

local Bookshelf = safe_require("koobone.bookshelf", true)
if not Bookshelf then return end

local ShelfView = safe_require("koobone.shelf_view", true)
if not ShelfView then return end

local Download = safe_require("koobone.download", true)
if not Download then return end

local DownloadProgress = safe_require("koobone.download_progress", true)
if not DownloadProgress then return end

local Reader = safe_require("koobone.reader", true)
if not Reader then return end

local Progress = safe_require("koobone.progress", true)
if not Progress then return end

local unpack_args = unpack or table.unpack

local function log_error(err)
    local text
    if type(err) == "table" then
        -- 展开 table 错误: 尝试 message 字段，否则遍历 key=value
        if err.message then
            text = tostring(err.message)
        else
            local parts = {}
            for k, v in pairs(err) do
                table.insert(parts, tostring(k) .. "=" .. tostring(v))
            end
            text = #parts > 0 and table.concat(parts, " ") or tostring(err)
        end
    else
        text = tostring(err)
    end
    text = text:gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function is_auth_error(err)
    return type(err) == "table" and err.auth_expired == true
end

local function display_error(err)
    if is_auth_error(err) then
        return _("登录已过期，请在 Koobone 设置中重新登录。")
    end
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local KoobonePlugin = WidgetContainer:extend{
    name = "koobone",
    is_doc_only = false,
    fullname = _("Koobone 漫画"),
    version = "0.2.0",
}

function KoobonePlugin:isCurrentDocKoobone()
    if not (self.ui and self.ui.document) then return false end
    local doc_path = self.ui.document.file or self.ui.document.path or ""
    if doc_path == "" then return false end
    return doc_path:lower():find('/koobone/', 1, true) ~= nil
end

function KoobonePlugin:init()
    self.settings = Settings:new()
    Log.init(self.settings)
    self.client = Client:new(self.settings)
    self.auth = Auth:new(self.settings)
    self.bookshelf = Bookshelf:new(self.settings, self.client)
    self.download = Download:new(self.settings, self.client, self.bookshelf)
    self.progress_ctor = Progress
    self.reader = Reader:new(self)
    self.shelf_view = ShelfView:new(self)

    -- 加载补丁（图片样式调整）
    local ok_patch, patch = pcall(require, "patches.core")
    if ok_patch and patch and patch.install then
        patch.install()
        Log.info("[Koobone] patches loaded")
    end

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    self:onDispatcherRegisterActions()

    Log.info("[Koobone] init: settings/client/auth/bookshelf/download/reader/shelf_view ok")
end

function KoobonePlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("show_koobone_bookshelf", {
        category = "none",
        event = "ShowKooboneBookshelf",
        title = _("Koobone 书架"),
        filemanager = true,
        reader = true,
    })
end

function KoobonePlugin:onShowKooboneBookshelf()
    self:showBookshelf()
end

function KoobonePlugin:safeCallback(label, callback)
    local self_ref = self
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack_args(args))
        end, debug.traceback)
        if not ok then
            if logger and logger.err then
                logger.err(LOG_MODULE, "action failed:", label, log_error(err))
            end
            self_ref:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end
end

function KoobonePlugin:showBusy(text)
    if self._busy_msg then
        UIManager:close(self._busy_msg)
    end
    self._busy_msg = InfoMessage:new{ text = text or _("请稍候..."), norefresh = true }
    UIManager:show(self._busy_msg)
    UIManager:forceRePaint()
end

function KoobonePlugin:closeBusy()
    if self._busy_msg then
        UIManager:close(self._busy_msg)
        self._busy_msg = nil
    end
end

function KoobonePlugin:showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function KoobonePlugin:_add_to_menu(menu_table, is_reader)
    local self_ref = self
    local sub_items = {
        {
            text = _("打开书架"),
            callback = self:safeCallback(_("打开书架"), function()
                self_ref:showBookshelf()
            end),
        },
        {
            text = _("设置"),
            separator = true,
            callback = self:safeCallback(_("设置"), function()
                self_ref:showSettings()
            end),
        },
        {
            text = _("关于插件"),
            callback = function()
                self_ref:showInfo(T(_("Koobone 漫画插件 v%1\n\n核心特性:\n• 书架浏览与排序（按更新/名称/最后阅读）\n• 漫画下载与断点续传（带进度条）\n• EPUB 缓存与 LRU 自动清理\n• 阅读进度云端同步\n• 智能预下载下 N 卷\n• 后台静默刷新不打断阅读"), self_ref.version))
            end,
        },
    }

    if is_reader and self:isCurrentDocKoobone() then
        table.insert(sub_items, 1, {
            text = _("返回 Koobone 书架"),
            callback = self:safeCallback(_("返回书架"), function()
                self_ref:showBookshelf()
            end),
        })
    end

    menu_table.koobone = {
        text = _("Koobone 漫画"),
        sorting_hint = "tools",
        sub_item_table = sub_items,
    }
end

function KoobonePlugin:addToMainMenu(menu_items)
    local is_reader = self.ui and self.ui.document ~= nil
    self:_add_to_menu(menu_items, is_reader)
end

function KoobonePlugin:showBookshelf(series_id_opt)
    local self_ref = self

    -- 1. 优先加载本地缓存，立即显示书架
    local cached_vols = nil
    if self.bookshelf then
        pcall(function()
            self.bookshelf:load_local_cache()
        end)
        cached_vols = self.bookshelf:get_vols()
    end

    -- 2. 如果有缓存，立即显示
    if cached_vols and #cached_vols > 0 then
        if self.shelf_view then
            self.shelf_view:show(series_id_opt, true)  -- skip_refresh=true，不触发网络请求
        end

        -- 3. 仅在首次打开书架时后台刷新数据（直接刷新，一步请求）
        -- 如果 cookie 失效，refresh 会返回 auth_error，再提示用户重新登录
        -- 后续打开只显示本地缓存，用户可手动点击"刷新书架"按钮更新
        if not self._shelf_initialized then
            self._shelf_initialized = true
            Async.run(function()
                return self_ref.bookshelf:refresh(true)
            end, function(ok_refresh, refresh_result, refresh_err)
                if not ok_refresh then
                    Log.error("[Koobone] refresh shelf failed:", tostring(refresh_err))
                    if is_auth_error(refresh_err) then
                        self_ref:showInfo(_("登录已过期，请在设置中重新登录"))
                    end
                    return
                end
                if refresh_result and type(refresh_result) == "table" and #refresh_result > 0 then
                    Log.info("[Koobone] 后台刷新书架完成, 共" .. #refresh_result .. "卷")
                    -- 不自动重新显示书架，避免打断用户操作（如在系列内下载漫画时闪回）
                    -- 数据已更新到本地缓存，用户下次打开书架或手动刷新时即可看到最新数据
                else
                    Log.warn("[Koobone] refresh failed: result is empty or nil")
                end
            end, { timeout = 120 })
        end
        return
    end

    -- 无缓存：直接刷新书架（合并登录检查和刷新为一步请求）
    if not self.bookshelf then
        self:showInfo(_("书架模块未加载"))
        return
    end

    self:showBusy(_("正在获取书架..."))
    Async.run(function()
        return self_ref.bookshelf:refresh(true)
    end, function(ok_refresh, refresh_result, refresh_err)
        self_ref:closeBusy()
        if not ok_refresh then
            if is_auth_error(refresh_err) then
                self_ref:showInfo(_("登录已过期，请在设置中重新登录"))
                self_ref:showSettings()
            else
                self_ref:showInfo(T(_("获取书架失败:\n%1"), display_error(refresh_err)))
            end
            return
        end
        -- bookshelf:refresh 返回 self.vols, nil
        if refresh_result and type(refresh_result) == "table" and #refresh_result > 0 then
            self._shelf_initialized = true
            if self_ref.shelf_view then
                self_ref.shelf_view:show(series_id_opt, true)
            end
        else
            self_ref:showInfo(_("获取书架失败：书架为空"))
        end
    end, { timeout = 120 })
end

function KoobonePlugin:refreshShelf()
    local self_ref = self
    self:showBusy(_("正在刷新书架..."))
    Async.run(function()
        local ok, err = self_ref.bookshelf:refresh(true)
        return { ok = ok, err = err }
    end, function(ok_run, result, err_run)
        self_ref:closeBusy()
        if not ok_run then
            self_ref:showInfo(T(_("刷新失败:\n%1"), display_error(err_run)))
            return
        end
        if not result.ok then
            if is_auth_error(result.err) then
                self_ref:showInfo(display_error(result.err))
            else
                self_ref:showInfo(T(_("刷新失败:\n%1"), display_error(result.err)))
            end
            return
        end
        self_ref:showInfo(_("书架刷新完成"))
        if self_ref.shelf_view then
            self_ref.shelf_view:show()
        end
    end, { timeout = 120 })
end

function KoobonePlugin:open_comic(vol_or_fmd)
    -- 直接用 KOReader 打开 EPUB 文件，不需要解压
    local vol = vol_or_fmd
    if type(vol_or_fmd) == "string" then
        if not self.bookshelf then
            self:showInfo(_("书架模块未加载"))
            return
        end
        vol = self.bookshelf:get_vol_by_fmd(vol_or_fmd)
        if not vol then
            self:showInfo(_("未找到该漫画"))
            return
        end
    end

    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then
        self:showInfo(_("漫画标识无效"))
        return
    end

    -- 检查 EPUB 文件是否存在
    local epub_path = self.download and self.download:_epub_path(fmd, vol.file_md5)
    if not epub_path or not lfs.attributes(epub_path, "mode") then
        self:showInfo(_("EPUB 文件未下载"))
        return
    end

    -- 直接用 KOReader 打开 EPUB
    local ok_ReaderUI, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_ReaderUI or not ReaderUI then
        self:showInfo(_("无法加载阅读器"))
        return
    end

    Log.info("[Koobone] 打开 EPUB: " .. epub_path)
    ReaderUI:showReader(epub_path)

    -- 自动设置"图片高度优先（铺满）"CSS 样式（延迟等待阅读器初始化）
    local UIManager_after = require("ui/uimanager")
    UIManager_after:scheduleIn(3.0, function()
        local ok_RST, ReaderStyleTweak = pcall(require, "apps/reader/modules/readerstyletweak")
        if not ok_RST or not ReaderStyleTweak then return end

        -- 获取当前 ReaderUI 实例
        local reader_instance = ReaderUI.instance
        if reader_instance and reader_instance.styletweak then
            local st = reader_instance.styletweak
            -- 检查是否已经设置过 koobone 样式
            if st.book_style_tweak and st.book_style_tweak:find("Koobone", 1, true) then
                Log.info("[Koobone] 图片高度优先样式已存在")
                return
            end
            -- 设置图片高度优先 CSS
            local css = [[
/* Koobone: 图片高度优先，尽量铺满 */
img, svg {
    height: 100vh !important;
    width: auto !important;
    max-width: 100% !important;
    object-fit: contain !important;
    margin: 0 auto !important;
    display: block !important;
}
body {
    margin: 0 !important;
    padding: 0 !important;
}
]]
            st.book_style_tweak = css
            st.book_style_tweak_enabled = true
            st.enabled = true
            -- 更新 CSS 文本并应用
            if st.updateCssText then
                pcall(function() st:updateCssText(true) end)
            end
            Log.info("[Koobone] 已应用图片高度优先样式")
        end
    end)

    -- 触发预下载：打开漫画后，在后台预下载后续 N 卷
    self:_trigger_preload(vol)
end

-- 预下载触发：按书架排序预下载当前卷后续的 N 卷（使用队列机制）
-- 预下载是后台静默操作，不弹任何提示，避免干扰阅读
function KoobonePlugin:_trigger_preload(current_vol)
    if not current_vol then return end
    if not self.download then return end
    if not self.bookshelf then return end

    local pre_chapters = tonumber(self.settings and self.settings:get_pre_download_chapters() or 0) or 0
    if pre_chapters <= 0 then return end

    local self_ref = self
    local current_fmd = tostring(current_vol.file_md5 or current_vol.fmd or "")

    -- 获取当前卷的系列 ID
    local series_id = current_vol.series_id or current_vol.series
    if not series_id or series_id == "" then
        Log.warn("[Koobone] 预下载：当前卷无系列 ID，跳过")
        return
    end

    -- 获取系列的所有卷
    local vols = self.bookshelf:get_series_vols(series_id)
    if not vols or #vols == 0 then
        Log.warn("[Koobone] 预下载：系列 " .. tostring(series_id) .. " 无卷")
        return
    end

    -- 找到当前卷的位置
    local current_idx = 0
    for i, v in ipairs(vols) do
        if tostring(v.file_md5 or v.fmd) == current_fmd then
            current_idx = i
            break
        end
    end

    if current_idx == 0 then
        Log.warn("[Koobone] 预下载：在系列中找不到当前卷 fmd=" .. current_fmd)
        return
    end

    -- 收集要预下载的卷
    local to_preload = {}
    for j = 1, pre_chapters do
        local idx = current_idx + j
        if idx > #vols then break end
        table.insert(to_preload, vols[idx])
    end

    if #to_preload == 0 then
        Log.info("[Koobone] 预下载：已到系列末尾，无更多卷可预下载")
        return
    end

    Log.info("[Koobone] 启动预下载：当前卷=" .. current_fmd .. " 系列=" .. tostring(series_id) .. " 预下载" .. #to_preload .. "卷")
    -- 预下载是静默后台操作，不弹提示

    -- 使用队列机制添加预下载任务（不订阅队列状态，不弹进度提示）
    local added, skipped = self.download:enqueue_batch(to_preload, {
        on_success = function(vol, epub_path)
            Log.info("[Koobone] 预下载成功: " .. tostring(vol.title or vol.fmd))
        end,
        on_fail = function(vol, err)
            Log.warn("[Koobone] 预下载失败: " .. tostring(vol.title or vol.fmd) .. " err=" .. tostring(err))
        end,
    })

    Log.info("[Koobone] 预下载已将 " .. tostring(added) .. " 卷加入队列，跳过 " .. tostring(skipped) .. " 卷")
end

function KoobonePlugin:download_comic(vol, force)
    if not vol then return end
    if not self.download then
        self:showInfo(_("下载模块未加载"))
        return
    end

    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then
        self:showInfo(_("无效的卷标识"))
        return
    end

    -- 如果强制重新下载（从操作菜单的"重新下载"按钮），跳过缓存检查
    if force then
        self:_do_download_comic(vol, true)
        return
    end

    -- 检查是否已缓存
    local already_downloaded = false
    if self.bookshelf then
        already_downloaded = self.bookshelf:is_vol_downloaded(vol)
    end
    if already_downloaded then
        local self_ref = self
        UIManager:show(ConfirmBox:new{
            text = _("该卷已下载，是否重新下载？"),
            ok_text = _("重新下载"),
            cancel_text = _("取消"),
            ok_callback = function()
                self_ref:_do_download_comic(vol, true)
            end,
        })
        return
    end

    self:_do_download_comic(vol, false)
end

function KoobonePlugin:_do_download_comic(vol, force_redownload)
    local self_ref = self
    local fmd = tostring(vol.file_md5 or vol.fmd or "")

    -- 如果强制重新下载，先清除旧缓存
    if force_redownload and self.download then
        pcall(function()
            self_ref.download:delete_vol_cache(fmd, vol.file_md5)
        end)
    end

    -- 生成子进程 IPC 文件路径（子进程写进度，父进程读）
    local ipc_paths = self.download:ipc_paths(fmd)
    self.download:ipc_cleanup(ipc_paths)  -- 清理上次残留

    -- 创建下载进度对话框
    local ok_DLProgress, DownloadProgress = pcall(require, "koobone.download_progress")
    local progress_dialog = nil
    local download_here = true  -- 标记是否在前台下载（用于"后台运行"切换）
    local poll_handle = nil     -- 轮询定时器句柄
    if ok_DLProgress and DownloadProgress then
        local vol_title = (vol and (vol.title or vol.vol_name)) or fmd
        progress_dialog = DownloadProgress:new{
            title = _("下载中"),
            on_cancel = function()
                Log.info("[Koobone] 用户取消下载 fmd=" .. fmd)
                self_ref._download_cancelled = true
                -- 通过 IPC 文件通知子进程取消
                self_ref.download:ipc_send_cancel(ipc_paths.cancel_file)
                -- 关闭进度对话框
                if progress_dialog then
                    progress_dialog:close()
                    progress_dialog = nil
                end
            end,
            on_background = function()
                Log.info("[Koobone] 后台运行下载 fmd=" .. fmd)
                download_here = false
                -- 关闭进度对话框，让下载在后台继续
                if progress_dialog then
                    progress_dialog:close()
                    progress_dialog = nil
                end
                self_ref:showInfo(_("下载已转入后台"))
            end,
        }
        if UIManager then
            progress_dialog:show()
        end
        progress_dialog:setState{
            stage = "prepare",
            vol_name = tostring(vol_title),
            percent = 0,
        }
    end

    -- 父进程轮询子进程写入的进度文件，更新对话框
    local function stop_polling()
        if poll_handle and UIManager then
            pcall(function() UIManager:unschedule(poll_handle) end)
            poll_handle = nil
        end
    end
    local function poll_progress()
        if not progress_dialog then return end
        local data = self_ref.download:ipc_read_progress(ipc_paths.progress_file)
        if data then
            progress_dialog:setState{
                stage = data.stage,
                vol_name = data.vol_name,
                download_bytes = data.current,
                expected_size = data.total,
                message = data.message,
            }
        end
        poll_handle = UIManager:scheduleIn(0.5, poll_progress)
    end
    if progress_dialog and UIManager then
        poll_handle = UIManager:scheduleIn(0.5, poll_progress)
    end

    -- 在后台线程下载 EPUB 文件
    self._download_cancelled = false
    local download_task = Async.run(function()
        -- 只下载 EPUB 文件，不解压
        -- 通过 IPC 文件传递进度给父进程
        local epub_path = self_ref.download:download_epub_file(vol, nil, self_ref, {
            progress_file = ipc_paths.progress_file,
            cancel_file = ipc_paths.cancel_file,
        })
        return epub_path
    end, function(ok, epub_path, err)
        -- 停止轮询
        stop_polling()

        -- 关闭进度对话框（如果还存在的话）
        if progress_dialog then
            progress_dialog:setState{ stage = "done", percent = 1 }
            if UIManager then
                progress_dialog:close()
            end
            progress_dialog = nil
        end

        -- 清理 IPC 文件
        self_ref.download:ipc_cleanup(ipc_paths)

        if self_ref._download_cancelled then
            self_ref:showInfo(_("下载已取消"))
            self_ref._download_cancelled = false
            return
        end

        if not ok then
            Log.error("[Koobone] download_comic async failed:", tostring(err))
            self_ref:showInfo(_("下载失败: ") .. tostring(err or "未知错误"))
            return
        end
        if epub_path then
            local vol_title = (vol and (vol.title or vol.vol_name)) or fmd
            self_ref:showInfo(T(_("《%1》下载完成！"), tostring(vol_title)))
            -- 刷新书架视图以反映下载状态
            if self_ref.shelf_view then
                self_ref.shelf_view:refresh_current()
            end
        else
            self_ref:showInfo(_("下载失败: ") .. tostring(err or "未知错误"))
        end
    end, { timeout = 600 })
end

function KoobonePlugin:showSettings()
    if not self.settings then
        self:showInfo(_("设置模块未加载"))
        return
    end

    -- 修复: 之前 menu_items 从未被赋值（xpcall 的返回值没被捕获），
    -- 导致即使 build_menu_items 成功，也永远走 "设置构建失败" 分支。
    -- 同时把错误写入 koobone 自己的日志（Log 模块），而非 KOReader 的 logger，
    -- 这样用户在 koobone.log 里才能看到错误详情。
    local menu_items
    local ok_build, result_or_err = xpcall(function()
        return self.settings:build_menu_items(self)
    end, debug.traceback)

    if ok_build then
        menu_items = result_or_err
    else
        Log.error("build_menu_items failed: " .. log_error(result_or_err))
        menu_items = {
            {
                text = _("设置构建失败，请查看日志"),
                enabled = false,
            },
        }
    end

    if type(menu_items) ~= "table" or #menu_items == 0 then
        menu_items = {
            {
                text = _("暂无设置项"),
                enabled = false,
            },
        }
    end

    -- 关闭旧的设置菜单（如果有）
    if self._settings_menu then
        pcall(function() UIManager:close(self._settings_menu) end)
        self._settings_menu = nil
    end

    local self_ref = self
    local settings_menu = Menu:new{
        title = _("Koobone 设置"),
        item_table = menu_items,
        items_per_page = 15,
        is_borderless = true,
        is_popout = false,
        -- 关键: close_callback 为空函数，点击叶子节点后菜单不自动关闭，
        -- 这样 InputDialog 弹出时菜单保留在后台，输入完成后菜单恢复可见，可继续操作。
        -- 用户按返回键仍可通过 onCloseWidget 关闭菜单。
        close_callback = function() end,
    }
    -- 菜单真正关闭时（按返回键）flush 设置
    settings_menu.onCloseWidget = function()
        if self_ref.settings then
            pcall(function() self_ref.settings:flush() end)
        end
        self_ref._settings_menu = nil
    end
    self._settings_menu = settings_menu
    UIManager:show(settings_menu)
end

function KoobonePlugin:showLog()
    if not Log then
        self:showInfo(_("日志模块未加载"))
        return
    end

    local log_path
    local ok_path, err_path = xpcall(function()
        return Log.get_log_file_path()
    end, debug.traceback)

    if not ok_path or not log_path then
        log_path = err_path and tostring(err_path) or nil
    end

    local log_content = ""
    if log_path then
        local f = io.open(log_path, "r")
        if f then
            log_content = f:read("*a") or ""
            f:close()
        end
    end

    if log_content == "" then
        log_content = _("(日志文件为空或不存在)")
        if log_path then
            log_content = log_content .. "\n\n" .. T(_("日志路径: %1"), log_path)
        end
    end

    if not TextViewer then
        self:showInfo(log_content:sub(1, 500))
        return
    end

    local viewer = TextViewer:new{
        title = T(_("Koobone 日志"), self.version),
        text = log_content,
        text_type = "book_info",
        justified = false,
    }
    UIManager:show(viewer)
end

function KoobonePlugin:onCloseWidget()
    if self.reader then
        pcall(function() self.reader:close_reader(false) end)
    end
    if self.shelf_view then
        pcall(function() self.shelf_view:close() end)
    end
    if self.settings then
        pcall(function() self.settings:flush() end)
    end
end

function KoobonePlugin:onExit()
    self:onCloseWidget()
    if self.settings then
        pcall(function() self.settings:flush() end)
    end
    if Log then
        pcall(function() Log.flush() end)
    end
end

function KoobonePlugin:onGesture(ev)
    if not self:isCurrentDocKoobone() then
        return false
    end
    if not GestureRange or not Screen or not Geom then
        return false
    end

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local top_right_zone = GestureRange:new{
        ges = "swipe",
        range = function()
            return Geom:new{
                x = screen_w * 0.7,
                y = 0,
                w = screen_w * 0.3,
                h = screen_h * 0.3,
            }
        end,
        direction = "south",
    }

    if top_right_zone:match(ev) then
        self:showSettings()
        return true
    end

    return false
end

return KoobonePlugin
