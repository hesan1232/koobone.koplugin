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

local Reader = safe_require("koobone.reader", true)
if not Reader then return end

local Info = safe_require("koobone.info", true)

local Koobone = safe_require("koobone.koobone", true)

local Patches = safe_require("patches.core", true)

local Progress = safe_require("koobone.progress", true)
if not Progress then return end

-- 自更新：updater_ui 负责菜单与流程编排，updater / digests / updater_http 由它按需 require。
-- 非必需模块 —— 加载失败只是「检查更新」不可用，插件本体照常工作。
local UpdaterUI = safe_require("koobone.updater_ui")

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
    fullname = Info and Info.fullname or _("Koobone 漫画"),
    version = Info and Info.version or "1.5.0",
}

-- ════════════════════════════════════════════════════════════════════════════
-- 「首页被别的控件遮住时，依然能收到 Dispatcher 派发的动作事件」
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【问题】UIManager:sendEvent（frontend/ui/uimanager.lua:884）先把事件送给窗口栈最上面
-- 那个非 toast 控件；它不消费时，才继续送给「该控件的 active_widgets」以及
-- 「is_always_active 的控件」。而 FileManager / ReaderUI 自身都不是 is_always_active
-- （全仓库只有前光 / 自然光 / 输入框 / 键盘等 6 处是），所以：
--
--   **只要有控件盖在首页之上**（例如第三方桌面类插件），Dispatcher 派发到本插件的
--   动作就永远送不到它。
--
-- 现象恰好是「菜单能打开书架、手势点了没反应」—— 菜单项是回调直接调方法，不走事件派发；
-- 手势要走 Dispatcher:execute → UIManager:sendEvent。（2026-10-11 在设备上实测确认：
-- 把覆盖首页的那个插件关掉，手势立刻恢复。）
--
-- 【上游留的口子】FileManager/ReaderUI:registerModule(name, module, always_active)
-- 第三个参数为 true 时会把 module 插进 self.active_widgets，注释写着
-- "to get events even when hidden"。但插件实例是由 PluginLoader 创建后交给
-- registerModule 的，第三个参数没传（= false）→ 插件默认收不到被遮挡时的事件。
-- 这里把自己补进去。（不能反过来去调 registerModule：它内部还会
-- table.insert(self, module)，会让插件在 FileManager 的数组部分出现两次，
-- propagateEvent 就会把它调两遍。）
--
-- 【为什么用一个「只放行自有事件」的桥，而不是把插件本身插进去】
--   ① 插件已经在 FileManager/ReaderUI 的**数组部分**（registerModule 里的
--      table.insert(self, ui_module)）。sendEvent 在「top_widget 自己」这条路径上
--      会经 WidgetContainer:propagateEvent 把事件送到插件一次；若插件同时也在
--      active_widgets 里，同一次 sendEvent 会在「top_widget 没消费」之后**再送一次**
--      （uimanager.lua:906-918）。桥只放行下面这几个自有事件，而这些事件的处理函数
--      都返回 true（= 已消费）→ 第一条路径就截断了，第二条根本轮不到桥，不会重复触发。
--   ② 桥把「因被遮挡而新增的接收面」严格限制在自有事件上 —— 插件永远不会因为被遮挡
--      而多收到 Touch / Gesture / KeyPress 等输入事件，行为零回归。
--
-- 幂等；ui 结构不符合预期时安全退出（退化为原有行为）。
--
-- 放行表用 Event.handler 名（frontend/ui/event.lua:31 是 `handler = "on"..name`）。
local DISPATCH_HANDLERS = {
    onShowKooboneBookshelf = true,
}

local function ensure_dispatch_reachable(plugin)
    local ui = plugin and plugin.ui
    if not ui or type(ui.active_widgets) ~= "table" then
        return false
    end
    local bridge = plugin._dispatch_bridge
    if not bridge then
        -- 桥只认「我们自己的事件」，其余一律返回 nil（不消费、不干扰上游传播）。
        bridge = {
            handleEvent = function(_, event)
                local handler = event and event.handler
                if not handler or not DISPATCH_HANDLERS[handler] then
                    return nil
                end
                return plugin:handleEvent(event)
            end,
        }
        plugin._dispatch_bridge = bridge
    end
    for _, w in ipairs(ui.active_widgets) do
        if w == bridge then return true end
    end
    table.insert(ui.active_widgets, bridge)
    if Log then
        pcall(function() Log.info("[Koobone] dispatcher bridge attached to ui.active_widgets") end)
    end
    return true
end

function KoobonePlugin:isCurrentDocKoobone()
    if not (self.ui and self.ui.document) then return false end
    local doc_path = self.ui.document.file or self.ui.document.path or ""
    if doc_path == "" then return false end
    return doc_path:lower():find('/koobone/', 1, true) ~= nil
end

-- ⚠️ 【为什么拆成 init + _init_modules：一个会「静默弄哑整个插件」的 KOReader 语义】
--
-- 上游创建插件实例的链路（已逐行核对）：
--   frontend/pluginloader.lua:479  PluginLoader:createPluginInstance(plugin, attr)
--                                  → local ok, re = pcall(plugin.new, plugin, attr)
--   frontend/ui/widget/widget.lua:40  Widget:new(o)
--                                  → if o._init then o:_init() end
--                                    if o.init  then o:init()  end
-- 合起来就是：**init() 里任何一处抛错，插件实例根本不会被创建**，现场只留下
--   logger.err("Failed to initialize", "<插件名>", "<错误>")
-- 一行日志（而且那条错误不会弹给用户）。
--
-- 后果对用户是什么样：插件的主菜单没了，它用 Dispatcher:registerAction 注册的手势/按键动作
-- 也没了；而 Dispatcher:execute 查到一个不存在的动作名时是**静默跳过**的
-- （frontend/dispatcher.lua:1504 `if Dispatcher:isActionEnabled(settingsList[k])`，
-- settingsList[k] 为 nil → 条件不成立 → 什么都不做、不报错）。
-- 于是现象就是「首页手势点了没反应」，而且完全看不出原因 —— 这正是本插件踩过的坑。
--
-- 所以把 init 拆开，保证「注册独立于模块构造」：
--   ① 动作注册最先跑，且不依赖任何模块（自身再包一层 pcall）；
--   ② 容易抛错的模块构造整段 pcall，失败只降级为「插件不可用」，但插件实例仍存在；
--   ③ 主菜单注册也单独 pcall。
function KoobonePlugin:init()
    pcall(function() self:onDispatcherRegisterActions() end)

    -- 让「首页被别的控件遮住」时也能收到 Dispatcher 派发的动作事件
    -- （原理见文件上方 ensure_dispatch_reachable 的注释）。
    -- 放在最前、且自身 pcall：它只做一次 table.insert，永远不会影响插件加载。
    pcall(function() ensure_dispatch_reachable(self) end)

    local ok_init, err_init = pcall(function() self:_init_modules() end)
    if not ok_init then
        self._init_error = tostring(err_init)
        if Log then
            pcall(function()
                Log.error("[Koobone] init 失败，插件降级为不可用：" .. tostring(err_init))
            end)
        end
    end

    if self.ui and self.ui.menu then
        pcall(function() self.ui.menu:registerToMainMenu(self) end)
    end
end

-- 真正做初始化（原 init 主体，逐字保留）。
function KoobonePlugin:_init_modules()
    -- ============================================================
    -- 关键：KOReader 会给 FileManager 和 ReaderUI 分别 new 一个 Plugin 实例，
    -- 两个 instance 的 self.xxx 互不互通！
    -- 所以模块句柄必须统一存在 State._shared 里，ReaderUI 模式直接复用。
    -- 否则：
    --   · FileManager 模式保存的 _last_open_series_id / bookshelf 引用 ReaderUI 都看不到
    --   · onShowToc 收到事件但 self.bookshelf=nil，build_items 一访问就 crash
    --   · bookshelf 重复 new 会丢缓存（内存态 SERIES_VOLS_MEM 是独立的）
    -- ============================================================
    local shared = State.getShared()
    if not State.isSharedInitialized() then
        -- FileManager 模式（或更早）：首次初始化，真实创建各个模块并写入 State._shared
        self.settings = Settings:new()
        State.bindSettings(self.settings)
        Log.init(self.settings)
        self.auth = Auth:new(self.settings)
        self.client = Client:new(self.settings, self.auth)
        self.bookshelf = Bookshelf:new(self.settings, self.client)
        self.download = Download:new(self.settings, self.client, self.bookshelf)
        self.reader = Reader:new(self)

        -- 加载补丁（图片样式调整）：提前安装，确保已打开的书也能立即生效
        self.patches_ok = false
        if Patches then
            self.patches_ok = true
            if Patches.install then
                Patches.install()
            end
            Log.info("[Koobone] patches installed")
        end

        State.bindSharedModules({
            settings = self.settings,
            client = self.client,
            auth = self.auth,
            bookshelf = self.bookshelf,
            download = self.download,
            reader = self.reader,
            shelf_view = ShelfView,
            ShelfView = ShelfView,
            patches_ok = self.patches_ok,
        })
        Log.info("[Koobone] init (FIRST/FILEMANAGER): settings/client/auth/bookshelf/download/reader/shelf_view ok -> bindSharedModules")

        -- 启动后延迟清理一次 EPUB 缓存（LRU）。
        -- 【为什么要延迟】清理要在 UI 线程同步遍历缓存目录、并对每个系列子目录递归
        -- 统计大小；直接写在 init() 里会拖慢冷启动，而缓存清理一点都不急（下一个
        -- 未预料的收益：用户不再下载新书时，也能回收「过期未再访问」的老文件 ——
        -- 光靠「下载成功后触发」是等不到的）。
        -- 只在首个（FileManager）实例上安排：ReaderUI 实例走的是复用分支。
        if self.download and self.download.maybe_lru_cleanup then
            local dl_ref = self.download
            UIManager:scheduleIn(10, function()
                pcall(function() dl_ref:maybe_lru_cleanup() end)
            end)
        end

        -- 更新自检 + 启动后的自动检查。
        -- 只放在「首个实例」分支里：KOReader 会给 FileManager 和 ReaderUI 各 new 一个
        -- Plugin，两边的 init 都会跑 —— 不区分的话每次打开书都会重复触发一遍检查。
        --
        -- ⚠️ 必须 pcall：本函数跑在 init 内部，而 init 抛错会让**整个插件不被加载**
        -- （见文件上方 init 的注释）。更新功能永远不该有「弄哑插件本体」的能力 ——
        -- 这条在 reading 那边一直是对的，这里是补齐。
        if UpdaterUI then
            local ok_up, err_up = pcall(UpdaterUI.startup, self)
            if not ok_up and Log then
                pcall(function()
                    Log.error("[Koobone] updater startup 失败（已忽略）：" .. tostring(err_up))
                end)
            end
        end
    else
        -- ReaderUI 模式（或后续 new 出来的实例）：直接复用 State._shared，不重复 new
        self.settings = shared.settings
        self.client = shared.client
        self.auth = shared.auth
        self.bookshelf = shared.bookshelf
        self.download = shared.download
        self.reader = shared.reader
        self.patches_ok = shared.patches_ok
        Log.info("[Koobone] init (SECOND/READERUI): reuse State._shared modules")
    end
    self.progress_ctor = Progress
    -- ShelfView 改为 fanqie 风格的纯函数式模块，不再实例化
    -- 由 KoobonePlugin:showBookList 内部持有返回的 menu 句柄（self.book_list_menu）
    self.book_list_menu = nil
end

function KoobonePlugin:onDispatcherRegisterActions()
    -- 动作名 / 事件名自 7d3ae0b（首个提交）以来从未变过 ——
    -- 用户在手势菜单里绑定的就是这个字符串，改名会让所有既有手势绑定失效
    -- （Dispatcher:execute 查不到动作名只会静默跳过，不报错）。改名属破坏性变更。
    --
    -- general = true（而**不是** filemanager = true）：
    --   · 上游 frontend/dispatcher.lua:889 / 1077 的 section 列表里，general 同时归入
    --     文件管理器与阅读界面两侧的手势菜单，所以首页手势能选到它；
    --   · 若再加 filemanager = true，会在手势菜单里**重复出现两项**（每个 section 各列一次），
    --     所以这里只写 general。
    Dispatcher:registerAction("show_koobone_bookshelf", {
        category = "none",
        event = "ShowKooboneBookshelf",
        title = _("Koobone 书架"),
        general  = true,
    })
end

-- 手势/按键派发的入口。和 reading 侧一样必须整体兜异常：
-- 入口抛错会冒泡进 KOReader 事件循环（2026-09-30 在 reading 上实测过：
-- 绑成手势后一点就让正在读的书一起没了）。showBookshelf 内部虽已自带 xpcall，
-- 但入口本身仍要兜住「方法不存在 / 调用约定变了」这类更早的失败。
function KoobonePlugin:onShowKooboneBookshelf()
    self:safeCallback(_("打开书架"), function()
        self:showBookshelf()
    end)()
    -- 返回 true =「事件已消费」。**必须**返回：插件同时挂在 FileManager 的数组部分与
    -- active_widgets 上时（见文件上方的 ensure_dispatch_reachable），若这里返回 nil，
    -- 同一次 sendEvent 会在 FileManager 未消费之后经 active_widgets 再送一次 ——
    -- 书架会被打开两次。
    return true
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
            sub_item_table_func = function()
                if not self_ref.settings then
                    return {
                        { text = _("设置模块未加载"), enabled = false },
                    }
                end
                local ok_build, menu_items = xpcall(function()
                    return self_ref.settings:build_menu_items(self_ref)
                end, debug.traceback)
                if not ok_build then
                    Log.error("build_menu_items failed: " .. tostring(menu_items))
                    return {
                        { text = _("设置构建失败，请查看日志"), enabled = false },
                    }
                end
                if type(menu_items) ~= "table" or #menu_items == 0 then
                    return {
                        { text = _("暂无设置项"), enabled = false },
                    }
                end
                return menu_items
            end,
        },
        {
            text = _("检查更新"),
            sub_item_table_func = function()
                if not UpdaterUI then
                    return { { text = _("更新模块未加载，请查看日志"), enabled = false } }
                end
                local ok_menu, items = xpcall(function()
                    return UpdaterUI.menu_items(self_ref)
                end, debug.traceback)
                if not ok_menu or type(items) ~= "table" then
                    Log.error("updater menu failed: " .. tostring(items))
                    return { { text = _("更新菜单构建失败，请查看日志"), enabled = false } }
                end
                return items
            end,
        },
        {
            text = _("关于插件"),
            callback = function()
                local about_text = (Info and Info.about_template)
                    or _("Koobone 漫画插件 v%1\n\n核心特性:\n• 书架浏览与排序（按更新/名称/最后阅读）\n• 漫画下载与断点续传（带进度条）\n• EPUB 缓存与 LRU 自动清理\n• 阅读进度云端同步\n• 智能预下载下 N 卷\n• 后台静默刷新不打断阅读")
                self_ref:showInfo(T(about_text, self_ref.version))
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

-- 统一显示书架/卷列表：已打开的菜单用 ShelfView.update 原地刷新，不关闭不重开
-- 参考 fanqie bookshelf.lua showBookList 逻辑
-- series_id_opt 语义（与 fanqie book_id 对齐）：
--   nil       → 保持当前视图状态（如果当前在卷目录视图，不强制切回系列列表）
--   "系列ID"  → 切到该系列的卷目录视图（与 fanqie 点书跳到目录一致）
--   false     → 强制切回系列列表视图（书架顶层）
function KoobonePlugin:showBookList(series_id_opt)
    return (xpcall(function()
    -- ShelfView 模块现在是纯函数式：show 返回 menu；update 直接对 menu 操作
    -- self.book_list_menu 持有当前打开的 menu 句柄（与 fanqie bookshelf.book_list_menu 一致）
    if self.book_list_menu then
        local current_opts = self.book_list_menu._shelf_view_opts or {}
        local effective_series_id
        if series_id_opt == nil then
            -- 无显式指定：保持当前视图（series_id 不变），避免用户在卷目录时被弹回系列列表
            effective_series_id = current_opts.series_id
        elseif series_id_opt == false then
            -- false：强制切回系列列表
            effective_series_id = nil
        else
            effective_series_id = series_id_opt
        end
        -- 旧菜单已存在：动态更新内容，保持当前页码/焦点，避免闪烁与白屏
        if effective_series_id == nil and (current_opts.series_id or "") ~= "" then
            -- 从卷目录切回系列列表：用 _clear_series 标志显式清除
            ShelfView.update(self.book_list_menu, { _clear_series = true })
        else
            ShelfView.update(self.book_list_menu, { series_id = effective_series_id })
        end
    else
        -- 菜单不存在：首次打开，创建新菜单。插件实例本身作为 opts.plugin 传入
        local effective_series_id
        if series_id_opt == nil or series_id_opt == false then
            effective_series_id = nil  -- 首次打开：默认系列列表（书架）
        else
            effective_series_id = series_id_opt
        end
        self.book_list_menu = ShelfView.show({
            plugin = self,
            series_id = effective_series_id,
            skip_refresh = true,
        })
        -- 当 ShelfMenu 关闭时，同步清空持有的句柄
        if self.book_list_menu then
            local old_on_close = self.book_list_menu.on_close_callback
            local plugin_ref = self
            self.book_list_menu.on_close_callback = function()
                plugin_ref.book_list_menu = nil
                if old_on_close then pcall(old_on_close) end
            end
        end
    end
    end, function(err)
        local msg = "[Koobone] showBookList FAIL:\n" .. tostring(err) .. "\n" .. tostring(debug and debug.traceback and debug.traceback() or "")
        if Log then pcall(function() Log.error(msg) end) end
        pcall(function() UIManager:show(require("ui/widget/infomessage"):new{ text = msg, timeout = 10 }) end)
        return nil
    end))
end

function KoobonePlugin:showBookshelf(series_id_opt, opts)
    return (xpcall(function()
    local self_ref = self
    opts = opts or {}
    local force_refresh = opts.force_refresh == true

    if not self.bookshelf or not ShelfView then
        self:showInfo(_("书架模块未加载"))
        return
    end

    -- api_key 直传鉴权：无需预检查 cookie/sess_key，请求时直接放到 X-KB-INFO 头。
    -- api_key 未配置时，ShelfView.show 会直接提示用户。

    -- ============================================================
    -- 分支1：force_refresh 或 首次无缓存 → 阻塞式网络请求
    -- ============================================================
    local function fallback_to_cache(label)
        -- 失败回退：尝试加载旧缓存显示，避免完全空白
        local cached_series = nil
        pcall(function()
            self_ref.bookshelf:load_local_cache()
            cached_series = self_ref.bookshelf:ensure_loaded()
        end)
        if cached_series and #cached_series > 0 then
            self_ref:showInfo(T(_("%1，已显示旧缓存"), label))
            self_ref:showBookList(series_id_opt)
            return true
        end
        return false
    end

    if force_refresh then
        -- force_refresh：清 L1 API 短缓存（进程内父进程版，避免父进程仍命中旧缓存）
        if self_ref.client then
            pcall(function()
                if self_ref.client.clearSeriesListCache then
                    self_ref.client:clearSeriesListCache()
                end
                if self_ref.client.clearVolListCache then
                    self_ref.client:clearVolListCache()
                end
            end)
        end
        self:showBusy(_("正在刷新书架..."))
        -- 刷新书架永远异步（bookshelf:refresh 内部会再次清三层缓存 + 打 HTTP）
        -- 即使 HTTP 慢（15 秒+），showBusy 也在前台显示，UI 不冻
        Async.run(function()
            return self_ref.bookshelf:refresh(true)
        end, function(ok_run, result, err_run)
            self_ref:closeBusy()
            if not ok_run then
                if is_auth_error(result) then
                    self_ref:showInfo(display_error(result))
                    return
                end
                if fallback_to_cache(display_error(result)) then return end
                self_ref:showInfo(T(_("刷新失败:\n%1"), display_error(result)))
                return
            end
            if not result then
                if is_auth_error(err_run) then
                    self_ref:showInfo(display_error(err_run))
                    return
                end
                if fallback_to_cache(display_error(err_run)) then return end
                self_ref:showInfo(T(_("刷新失败:\n%1"), display_error(err_run)))
                return
            end
            self_ref._shelf_initialized = true
            -- 关键：refresh 在 Async.run 子进程里执行，子进程对 SERIES_MEM_CACHE/SERIES_VOLS_MEM
            -- 的修改不影响父进程。必须用 apply_refresh_result 把子进程返回的 series + all_vols
            -- 重新写入父进程内存，否则刷新后界面仍是旧数据（需重启插件才生效）
            if type(result) == "table" and result.series then
                pcall(function()
                    self_ref.bookshelf:apply_refresh_result(result)
                end)
            end
            self_ref:showBookList(series_id_opt)
            -- 封面下载交给 ShelfView.show 后的 trigger_cover_download（逐个下载+每个yield UI）
            -- 不在这个回调里再 fork 第二个 Async.run（连续fork会导致UI卡顿）
        end, { timeout = 120, poll_interval = 0.3 })
        return
    end

    -- ============================================================
    -- 分支2：非 force_refresh → 先立即显示缓存，再后台静默刷新
    -- ============================================================
    local has_cache = false
    local cached_series = nil
    pcall(function()
        cached_series = self_ref.bookshelf:load_local_cache()
    end)
    if cached_series and #cached_series > 0 then
        has_cache = true
    end

    -- -------- 边界：指定了切到卷目录，但卷目录缓存未命中 --------
    --   这时如果直接 showBookList(series_id_opt)，build_items 同步
    --   返回空 items，ShelfView.show 会提示"该系列无卷"。
    --   改用：先 loading + 后台异步 get_series_vols（会填缓存 + 持久化），
    --   成功后再 showBookList → 0 延迟不闪白。
    local need_async_vol_dir = false
    if has_cache and series_id_opt and series_id_opt ~= false then
        local ok_v, cur_vols = pcall(function()
            return self_ref.bookshelf:get_series_vols(series_id_opt)
        end)
        if not ok_v or not cur_vols or #cur_vols == 0 then
            need_async_vol_dir = true
        end
    end

    if has_cache and not need_async_vol_dir then
        self:showBookList(series_id_opt)
    end

    -- 异步拉取目录（边界场景）：先 loading 再切卷目录
    if need_async_vol_dir then
        self:showBusy(_("正在加载目录..."))
        local sid_for_dir = series_id_opt
        Async.run(function()
            return self_ref.bookshelf and self_ref.bookshelf:get_series_vols(sid_for_dir)
        end, function(ok_run, vols, err_run)
            self_ref:closeBusy()
            if not ok_run or not vols or #vols == 0 then
                if is_auth_error(vols) then
                    self_ref:showInfo(display_error(vols))
                    return
                end
                self_ref:showInfo(T(_("加载目录失败:\n%1"),
                    display_error(err_run or vols or _("无数据"))))
                -- 失败但还是尝试 showBookList，让用户看到底
                self_ref:showBookList(series_id_opt)
                return
            end
            self_ref:showBookList(series_id_opt)
        end, { timeout = 90, poll_interval = 0.3 })
    end

    -- 首次打开书架（_shelf_initialized=false）或无缓存 → 后台静默刷新
    if not self._shelf_initialized or not has_cache then
        if not has_cache then
            self:showBusy(_("正在获取书架..."))
        end
        Async.run(function()
            return self_ref.bookshelf:refresh(false)
        end, function(ok_run, result, err_run)
            if not has_cache then
                self_ref:closeBusy()
            end
            if not ok_run then
                if is_auth_error(result) then
                    if not has_cache then
                        self_ref:showInfo(display_error(result))
                    end
                    return
                end
                if has_cache then
                    -- 有缓存时后台静默刷新失败，保留现有显示不打扰
                    Log.warn("[Koobone] 后台刷新失败:", tostring(result))
                    return
                end
                -- 无缓存且失败 → 回退到旧缓存或报错
                if fallback_to_cache(display_error(result)) then return end
                self_ref:showInfo(T(_("获取书架失败:\n%1"), display_error(result)))
                return
            end
            if not result then
                if is_auth_error(err_run) then
                    if not has_cache then
                        self_ref:showInfo(display_error(err_run))
                    end
                    return
                end
                if has_cache then
                    Log.warn("[Koobone] 后台刷新失败(无结果):", tostring(err_run))
                    return
                end
                if fallback_to_cache(display_error(err_run)) then return end
                self_ref:showInfo(T(_("获取书架失败:\n%1"), display_error(err_run)))
                return
            end
            self_ref._shelf_initialized = true
            -- 同 force_refresh 分支：apply_refresh_result 把子进程的 series + all_vols
            -- 重新写入父进程内存，解决 Async.run 跨进程隔离
            if type(result) == "table" and result.series then
                pcall(function()
                    self_ref.bookshelf:apply_refresh_result(result)
                end)
            end
            -- 成功：用 ShelfView.update 原地更新，不关闭旧菜单
            if has_cache then
                if self_ref.book_list_menu then
                    ShelfView.update(self_ref.book_list_menu, { series_id = series_id_opt })
                end
            else
                self_ref:showBookList(series_id_opt)
            end
            -- 封面下载交给 ShelfView.show/update 后的 trigger_cover_download（逐个下载）
        end, { timeout = 120, poll_interval = 0.3 })
        return
    end

    -- 已有缓存且已初始化：不再重复后台刷新，用户手动点刷新再更新
    end, function(err)
        local msg = "[Koobone] showBookshelf FAIL:\n" .. tostring(err) .. "\n" .. tostring(debug and debug.traceback and debug.traceback() or "")
        if Log then pcall(function() Log.error(msg) end) end
        pcall(function() UIManager:show(require("ui/widget/infomessage"):new{ text = msg, timeout = 10 }) end)
        return nil
    end))
end


function KoobonePlugin:open_comic(vol_or_fmd)
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

    local epub_path = self.download and self.download:_resolve_epub_path(vol, fmd, vol.file_md5)
    if not epub_path or not lfs.attributes(epub_path, "mode") then
        self:showInfo(_("EPUB 文件未下载"))
        return
    end

    local ok_ReaderUI, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_ReaderUI or not ReaderUI then
        self:showInfo(_("无法加载阅读器"))
        return
    end

    -- 换书 = 先给上一本书的会话收尾（**含最后一次上传**），再开新会话。
    -- ⚠️ 顺序不能反：start_progress_session 会直接替换 self._progress，
    -- 被替换掉的旧 Progress 就再也没机会上传了 —— 而且 start_progress_session 还会清空
    -- 会话归属，旧 ReaderUI 的关闭不再触发 close_reader，等于旧进度被静默丢弃。
    -- 这一条正好补上「①/② 不再误杀会话」之后留下的空档（见 onCloseWidget 的说明）。
    if self.reader and self.reader._current_vol then
        pcall(function() self.reader:close_reader(true) end)
    end
    if self.reader then
        self.reader:start_progress_session(vol)
    end

    -- 保存当前卷信息，供阅读界面点击目录(onShowToc)时回到对应系列的卷目录页。
    -- 存 State（跨 ReaderUI/FileManager 两个 Plugin 实例共享），不存 self.xxx，
    -- 否则 ReaderUI 实例 new 出来后 self._last_open_series_id=nil，onShowToc 查不到。
    local series_id = vol.series_id or vol.series or vol.vol_seriesid
    if not series_id or series_id == "" then
        -- fallback: 用系列名作为缓存键（sna）
        local sna = vol.series_title or vol.vol_series or vol.sna
        if sna and sna ~= "" then series_id = sna end
    end
    State.setLastOpenVol(vol, series_id)
    -- 切换漫画上下文：重置 pre_download_triggered 重入标志
    State.setCurrentComic(vol)

    Log.info("[Koobone] 打开 EPUB: " .. tostring(epub_path) .. " sid=" .. tostring(series_id))
    ReaderUI:showReader(epub_path)

    self:_trigger_preload(vol)
end

-- 预下载触发：按卷目录顺序预下载当前卷后续的 N 卷（使用队列机制）
-- 预下载是后台静默操作，不弹任何提示，避免干扰阅读
function KoobonePlugin:_trigger_preload(current_vol)
    if not current_vol then return end
    if not self.download then return end
    if not self.bookshelf then return end

    -- 问题3修复①：防重入——同一漫画上下文（State.current_comic）只触发一次预下载
    -- open_comic 里调 State.setCurrentComic(vol) 会重置此标志为 false
    -- 切换卷（卷目录顺序跳读到下一卷）不会触发 setCurrentComic，所以同一本漫画内只预下载一次
    -- 避免连续翻页重复入队、也避免阅读时翻页触发预下载导致局刷
    if State.isPreDownloadTriggered and State.isPreDownloadTriggered() then
        Log.debug("[Koobone] 预下载：已触发过（同一漫画上下文），跳过重复入队")
        return
    end

    local pre_chapters = tonumber(self.settings and self.settings:get_pre_download_chapters() or 0) or 0
    if pre_chapters <= 0 then
        Log.debug("[Koobone] 预下载：设置中关闭（pre_chapters<=0），跳过")
        return
    end

    local current_fmd = tostring(current_vol.file_md5 or current_vol.fmd or "")

    -- 获取当前卷的系列 ID
    local series_id = current_vol.series_id or current_vol.series
    if not series_id or series_id == "" then
        Log.warn("[Koobone] 预下载：当前卷无系列 ID，跳过")
        return
    end

    -- 获取系列的所有卷（目录顺序：vol_snumber 升序）
    local vols = self.bookshelf:get_series_vols(series_id)
    if not vols or #vols == 0 then
        Log.warn("[Koobone] 预下载：系列 " .. tostring(series_id) .. " 无卷")
        return
    end

    -- 找到当前卷的位置（按 file_md5 匹配，找不到 fallback 按标题匹配）
    local current_idx = 0
    for i, v in ipairs(vols) do
        if tostring(v.file_md5 or v.fmd) == current_fmd then
            current_idx = i
            break
        end
    end
    if current_idx == 0 then
        -- fallback：标题匹配（容错，因为可能卷缓存是旧版本 file_md5 对不上）
        local cur_title = tostring(current_vol.title or current_vol.vol_name or "")
        for i, v in ipairs(vols) do
            if tostring(v.title or v.vol_name or "") == cur_title and cur_title ~= "" then
                current_idx = i
                Log.info("[Koobone] 预下载：当前卷 fmd 未命中，按标题匹配成功 idx=", current_idx)
                break
            end
        end
    end
    if current_idx == 0 then
        Log.warn("[Koobone] 预下载：在系列中找不到当前卷 fmd=" .. current_fmd)
        return
    end

    -- 收集要预下载的卷
    -- 问题3修复②：跳过已下载 & 正在下载中的卷（只预下载真正需要的，减少 on_success 回调）
    local to_preload = {}
    for j = 1, pre_chapters do
        local idx = current_idx + j
        if idx > #vols then break end
        local cand = vols[idx]
        local cand_fmd = tostring(cand.file_md5 or cand.fmd or "")
        -- 已下载 → 跳过
        if self.bookshelf:is_vol_downloaded(cand) then
            Log.debug("[Koobone] 预下载跳过(已缓存):", tostring(cand.title or cand_fmd))
        -- 正在下载中 → 跳过
        elseif self.download:is_downloading(cand_fmd) then
            Log.debug("[Koobone] 预下载跳过(下载中):", tostring(cand.title or cand_fmd))
        -- 已在下载队列 → 跳过（enqueue_batch 内部也会检查，但这里先过一遍日志清晰）
        elseif self.download:is_enqueued(cand_fmd) then
            Log.debug("[Koobone] 预下载跳过(已在队列):", tostring(cand.title or cand_fmd))
        else
            table.insert(to_preload, cand)
        end
    end

    if #to_preload == 0 then
        Log.info("[Koobone] 预下载：无需要下载的卷（已缓存/已到末尾）")
        return
    end

    -- 到此决定真的入队，先标记重入
    if State.markPreDownloadTriggered then State.markPreDownloadTriggered() end

    Log.info("[Koobone] 启动预下载：当前卷=" .. current_fmd .. " 系列=" .. tostring(series_id)
        .. " 当前idx=" .. current_idx .. " 预下载" .. #to_preload .. "卷")
    -- 预下载是静默后台操作，不弹提示

    -- 问题3修复③：预下载的 on_success / on_fail 回调里不要 refresh_current 不要任何 UI 操作，
    -- 只做 markVolDownloaded（让缓存状态正确），并且 on_success 里也不直接 mark，
    -- 交给 download.lua Queue 回调里统一处理 markVolDownloaded。
    local added, skipped = self.download:enqueue_batch(to_preload, {
        pre_downloading = true, -- 告诉 download/state 这是预下载模式，少刷 UI
        on_success = function(vol, epub_path)
            Log.info("[Koobone] 预下载成功: " .. tostring(vol.title or vol.fmd))
            if self.bookshelf then
                pcall(function() self.bookshelf:markVolDownloaded(vol, true) end)
            end
        end,
        on_fail = function(vol, err)
            Log.warn("[Koobone] 预下载失败: " .. tostring(vol.title or vol.fmd) .. " err=" .. tostring(err))
        end,
    })

    Log.info("[Koobone] 预下载已将 " .. tostring(added) .. " 卷加入队列，跳过 " .. tostring(skipped) .. " 卷")
end


--- 本插件实例是不是「当前进度会话」的承载者？见 onCloseWidget 的完整说明。
-- 注意形参名不叫 self：main.lua 里出现「以 self 为名的局部函数」会让静态检查工具
-- 判定 self 被重绑定，从而整体跳过本文件的 self 方法检查（等于自废检查）。
local function is_session_owner(plugin)
    local reader = plugin.reader
    return reader ~= nil
        and type(reader.is_session_owner) == "function"
        and reader:is_session_owner(plugin.ui)
end

function KoobonePlugin:onCloseWidget()
    -- ⚠️ 这个钩子会在**四种**完全不同的时刻触发，只有其中一种该结束会话：
    --   ① 书架/文件管理器打开一本漫画 —— FileManager:onShowingReader → FileManager:onClose()
    --      → UIManager:close(FileManager) → CloseWidget 沿 propagateEvent 播到插件；
    --   ② 阅读中换卷 —— ReaderUI:showReader 先 broadcastEvent("ShowingReader")
    --      → **旧** ReaderUI:onShowingReader → onClose(false)，同样播到插件；
    --   ③ 用户退出阅读（真正该结束会话并上传的那一次）；
    --   ④ 插件所在 ui 的其它关闭路径。
    -- ① 和 ② 都发生在 open_comic() 里 start_progress_session() **之后**，
    -- 一律把新会话掐掉的话，30s 周期同步、云端进度拉取、关闭时推送、跳转到上次阅读页
    -- 全部失效 —— 这才是「进度同步一直不生效」的真正根因。
    --
    -- ⚠️ 判据不能是「是不是 ReaderUI」：② 里关闭的旧 ReaderUI 也是 ReaderUI。
    -- 只能是「归属」—— 见 koobone/reader.lua 的 claim_session：会话由承载它的那个
    -- ReaderUI 实例上的插件在 onReaderReady 时认领，只有认领者关闭才算「用户离开了这本书」。
    -- （也不看 self.ui.document：ReaderUI:onClose 是 closeDocument()（document=nil）之后才
    --   UIManager:close(self)，轮到插件时 document 早就是 nil 了。）
    --
    -- 原实现两种情况都执行 close_reader(false)，除了上面的①/②误杀，还有第二个后果：
    -- skip_upload=true 让「退出阅读时的最后一次推送」也永远不会发出。
    if is_session_owner(self) then
        pcall(function() self.reader:close_reader(true) end)
    end
    if self.book_list_menu then
        ShelfView.close(self.book_list_menu)
    end
    if self.settings then
        pcall(function() self.settings:flush() end)
    end
end

--- ReaderUI 文档加载完成：把当前进度会话认领到本实例的 ui 上（见 onCloseWidget / Reader:claim_session）。
-- ⚠️ 必须返回 nil（不能返回 true）：事件沿 propagateEvent 传播，
-- 返回 true 会截断后续模块的 onReaderReady（ReaderFooter / ReaderRolling 等都靠它）。
function KoobonePlugin:onReaderReady()
    if self.reader and type(self.reader.claim_session) == "function" then
        pcall(function() self.reader:claim_session(self.ui) end)
    end
end

--- 翻页：把当前页码实时喂给进度会话。
--
-- 为什么必须有这两个钩子：Progress 里的页码此前**只**由 30s 周期同步更新，
-- 于是「退出阅读时的最后一次推送」推的是最多 30s 前的页码 —— 短时阅读（漫画常见：
-- 翻几十页就退出）甚至会把「起始页」当成进度推上去，等于没推。
-- 上游 readerpaging / readerrolling 每翻一页都派发 PageUpdate，滚动模式只派发 PosUpdate
-- （PosUpdate 的第二个参数才是页码）—— 所以两个都要接，只接一个会在另一种模式下静默停滞。
--
-- 页码基准：PageUpdate/PosUpdate 给的是 document 的 0-based 页号，与 Progress 内部约定
-- 一致（_upload_now 上传时 +1 转成云端 1-based），无需换算。
-- 只走 update_local_progress（纯内存，不触发上传）：上传节奏仍由 start_session 里的
-- interval 定时器统一负责，避免翻页时各自发请求。
-- ⚠️ 全程不得抛错：这条路径在用户翻页的手势链上，异常会一路冒到 KOReader 事件循环。
function KoobonePlugin:onPageUpdate(pageno)
    local page = tonumber(pageno)
    if not page or page < 0 then return end
    if not is_session_owner(self) then return end
    local prog = self.reader and self.reader._progress
    if not prog then return end
    pcall(function() prog:update_local_progress(page) end)
end

function KoobonePlugin:onPosUpdate(_pos, pageno)
    -- 滚动模式只派发 PosUpdate：转发给 onPageUpdate，保证两条路都有页码。
    if pageno ~= nil then
        self:onPageUpdate(pageno)
    end
end

function KoobonePlugin:onExit()
    -- 退出应用：取消所有在途的异步子进程（卷目录 / 封面 / 进度拉取）。
    --
    -- ⚠️ 这一步**不能**放进 onCloseWidget：那个钩子在「从文件管理器打开一本书」时也会
    -- 触发（FileManager:onShowingReader → FileManager:onClose → 事件传播到插件），
    -- 而那一刻阅读会话的「自动拉取云端进度」刚刚发起 —— 一刀切会把自动拉取进度直接掐掉。
    -- 只有真正退出 KOReader 才该全清。
    --
    -- ⚠️ 顺序：先掐在途异步，**再**收尾会话。反过来会自杀 ——
    --    「退出 KOReader 时正在阅读」这条路径上，onCloseWidget 会走 close_reader(true)，
    --    内部立刻发一个「最后一次进度上传」的子进程，紧接着的 cancel_all 正好把它杀掉。
    if Async and Async.cancel_all then
        pcall(function() Async.cancel_all() end)
    end
    self:onCloseWidget()
    if self.settings then
        pcall(function() self.settings:flush() end)
    end
    if Log then
        pcall(function() Log._flush() end)
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
        -- ⚠️ onGesture 由用户手势直接触发，任何 Lua error 都会冒泡到 KOReader 事件循环 → 整个进程崩溃。
        -- 而 `showSettings` 在插件上从未定义过（设置项已挂在主菜单 addToMainMenu 下），
        -- 原来的 `self:showSettings()` 必然抛 "attempt to call method 'showSettings' (a nil value)"。
        -- 这里按「可选钩子」处理：有实现才调用，没有就记日志忽略，顺带保留将来补实现的挂点。
        local show_settings = self.showSettings
        if type(show_settings) == "function" then
            local ok_g = pcall(show_settings, self)
            if not ok_g and Log then
                pcall(function() Log.warn("[Koobone] onGesture: showSettings 执行失败，已忽略") end)
            end
        elseif Log then
            pcall(function()
                Log.warn("[Koobone] onGesture: showSettings 未实现，忽略右上角下滑手势")
            end)
        end
        return true
    end

    return false
end

-- 拦截阅读界面的"目录"按钮：当用户点击 KOReader 阅读器的目录（T 键/菜单→目录）时，
-- 不显示 KOReader 默认的 EPUB TOC（漫画是整卷，EPUB 内部 TOC 没有意义），
-- 而是在阅读界面上方"覆盖显示"插件自己的卷目录页（ShelfMenu，series_id = 当前卷的系列）。
-- 这样目录关闭后用户仍回到阅读界面，不会丢当前阅读进度。
-- 关键点：不要关 ReaderUI（之前硬关 ReaderUI + 立即 show 新 Menu 有 UI 线程竞态，直接闪退）。
-- 关键防御：**全部路径 xpcall + debug.traceback**，确保任何可能的闪退点都会被 koobone.log 捕获，
-- 否则 Lua error 直接冒泡到 KOReader 事件循环，会触发 KOReader "程序出错"对话框或直接崩溃。
function KoobonePlugin:onShowToc()
    local start_ms = os and os.time and os.time() or 0
    local self_ref = self
    local function wrap(label, fn)
        return function(...)
            local args = { ... }
            local ok, err = xpcall(function()
                return fn(unpack(args))
            end, debug.traceback)
            if not ok then
                local msg = "[Koobone] onShowToc step FAIL: " .. tostring(label) .. "\n" .. tostring(err)
                if Log then pcall(function() Log.error(msg) end) end
                pcall(function() UIManager:show(require("ui/widget/infomessage"):new{ text = tostring(msg), timeout = 8 }) end)
            end
        end
    end

    local ok_xp, xp_result = xpcall(function()
        if not self:isCurrentDocKoobone() then
            return false  -- 不是我们插件的书：放过，让 ReaderToc 默认实现显示
        end
        local series_id = State.getLastOpenSeriesId()
        if not series_id or series_id == "" then
            if Log then pcall(function() Log.warn("[Koobone] onShowToc: State.getLastOpenSeriesId 为空，退回书架主页") end) end
        end
        if Log then pcall(function() Log.info("[Koobone] onShowToc START sid=", tostring(series_id), " t=", tostring(start_ms)) end) end

        -- 目录页本身就是 ShelfMenu（一个 Menu 组件），UIManager:show 在 ReaderUI 之上。
        -- 左上角按钮点击时，按 ShelfMenu:onLeftButtonTap 行为：目录视图 → 返回系列列表（书架）
        -- 书架再左上角返回时才真正回到 FileManager / ReaderUI（因为 ReaderUI 还在底下，
        -- show 模式下 Menu 是"对话框"式的，关闭后露出底下 ReaderUI，阅读进度不丢失）。
        -- 如果用户点击某卷 → show_vol_action_dialog → 点"开始阅读"会走 open_comic →
        --   ReaderUI:showReader 再次加载新 EPUB，这个路径是安全的。
        local function open_shelf_or_toc()
            if Log then pcall(function() Log.info("[Koobone] onShowToc -> showBookshelf(", tostring(series_id), ")") end) end
            if series_id and series_id ~= "" then
                self_ref:showBookshelf(series_id)
            else
                self_ref:showBookshelf()
            end
            if Log then pcall(function() Log.info("[Koobone] onShowToc -> showBookshelf DONE") end) end
        end
        local bookshelf_ok = self.bookshelf and true or false
        if not bookshelf_ok then
            self:showInfo(_("书架模块未加载"))
            return true
        end
        local sid_for_check = series_id
        local dir_cached = false
        local v
        if sid_for_check then
            -- 修复：用 peek_series_vols 只查缓存不打 API，避免同步阻塞卡死 UI
            local ok_c
            ok_c, v = xpcall(function()
                if self.bookshelf.peek_series_vols then
                    return self.bookshelf:peek_series_vols(sid_for_check)
                end
                return self.bookshelf:get_series_vols(sid_for_check)
            end, debug.traceback)
            if not ok_c then
                if Log then pcall(function() Log.error("[Koobone] onShowToc: cache-hit check xpcall fail:\n" .. tostring(v)) end) end
            end
            if ok_c and v and #v > 0 then dir_cached = true end
        end

        if dir_cached then
            if Log then pcall(function() Log.info("[Koobone] onShowToc: CACHE HIT, count=", tostring(type(v)=="table" and #v or "?")) end) end
            -- 目录缓存命中 → 立即在 ReaderUI 上方显示目录页（0 延迟）
            wrap("open_shelf_or_toc(cached)", open_shelf_or_toc)()
        else
            if Log then pcall(function() Log.info("[Koobone] onShowToc: CACHE MISS, going async") end) end
            -- 缓存未命中：先加载提示再异步拉目录，避免 showBookshelf 走同步 build_items
            -- 返回空 {} 然后显示"该系列无卷"（看起来像 bug）。目录拉完再 show。
            -- 修复：原来这里读的是 `ok_Async`，而 main.lua 从未定义过该变量（只有 shelf_view.lua
            -- 内部有同名 local，不跨文件）→ ok_a 恒为 nil → 整个异步加载分支永远走不到，
            -- 每次都只弹"异步不可用"。Async 在本文件顶部已 require 且缺失即 return，
            -- 这里只需问它自身可用性。
            local ok_a = Async and Async.is_available and Async.is_available()
            if not ok_a then
                self:showInfo(_("异步不可用"))
                return true
            end
            -- 保存局部 loading，防止 onShowToc 被重复调用多次同时弹多个 loading
            if self._toc_loading then return true end
            self._toc_loading = true
            local loading = InfoMessage:new{ text = _("正在加载目录...") }
            UIManager:show(loading)
            UIManager:scheduleIn(0, wrap("scheduleIn TOC async", function()
                Async.run(function()
                    return self_ref.bookshelf and self_ref.bookshelf:get_series_vols(sid_for_check)
                end, wrap("TOC async result callback", function(ok, vols, err)
                    self_ref._toc_loading = nil
                    pcall(function() UIManager:close(loading) end)
                    if not ok or not vols or #vols == 0 then
                        UIManager:show(InfoMessage:new{
                            text = T(_("目录加载失败:\n%1"), tostring(err or vols or _("无数据"))),
                            timeout = 3,
                        })
                        return
                    end
                    if Log then pcall(function() Log.info("[Koobone] onShowToc: async DONE, vol count=", tostring(#vols)) end) end
                    open_shelf_or_toc()
                end), { timeout = 60, poll_interval = 0.3 })
            end))
        end
        return true  -- 吃掉 ShowToc 事件，阻止 ReaderToc 默认 EPUB 目录显示
    end, function(err)
        local msg = "[Koobone] onShowToc TOP FAIL:\n" .. tostring(err) .. "\n" .. tostring(debug.traceback())
        if Log then pcall(function() Log.error(msg) end) end
        pcall(function() UIManager:show(require("ui/widget/infomessage"):new{ text = msg, timeout = 12 }) end)
        return true  -- 出错也返回 true：拦截默认 TOC，用户看到报错不至于直接闪退
    end)
    if not ok_xp then return true end
    return xp_result
end

return KoobonePlugin
