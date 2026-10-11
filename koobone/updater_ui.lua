-- 自更新功能的 UI 与流程编排。
--
-- 【为什么和 updater.lua 分开】updater.lua 是纯逻辑、不碰任何 UI 对象，这样才能被丢进
-- `Async.run` 的子进程里跑（fork 出来的子进程碰 UIManager 会出问题）。本模块留在主线程，
-- 只管「什么时候调、出错怎么提示、装完怎么问重启」。
--
-- 【所有网络/文件操作都走 Async.run】KOReader 主线程一旦阻塞就是整机无响应（墨水屏上
-- 等同假死）。子进程不可用时 Async 会降级成 scheduleIn 里同步执行 —— 那会卡一小会儿，
-- 但至少不会崩，且是上游既有的降级语义。

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = (ok_ffiutil and ffiutil and ffiutil.template) or function(str) return str end

local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")

local Async = require("koobone.async")
local Updater = require("koobone.updater")
local Log = require("koobone.logger")

local UI = {}

local AUTO_CHECK_DELAY = 5             -- 启动后多久开始自动检查（秒）
local DEFAULT_INTERVAL = 24 * 60 * 60  -- 默认检查间隔：每天

-- ============================================================
-- 偏好读写
-- ============================================================

local function prefs(plugin)
    local stored
    if plugin.settings then
        stored = plugin.settings:get("updater")
    end
    if type(stored) ~= "table" then stored = {} end
    return stored
end

local function save_prefs(plugin, value)
    if not plugin.settings then return end
    plugin.settings:set("updater", value or {})
    plugin.settings:flush()
end

local function get_updater(plugin)
    if not plugin._updater then
        plugin._updater = Updater:new{ version = plugin.version }
    end
    return plugin._updater
end

local function is_online()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr then return false end
    local ok_check, connected = pcall(function() return NetworkMgr:isConnected() end)
    return ok_check and connected == true
end

local function interval_label(seconds)
    local value = tonumber(seconds) or DEFAULT_INTERVAL
    if value <= 24 * 60 * 60 then return _("每天") end
    if value <= 3 * 24 * 60 * 60 then return _("每 3 天") end
    return _("每 7 天")
end

local function restart_label(mode)
    if mode == "auto" then return _("自动重启") end
    if mode == "never" then return _("稍后手动重启") end
    return _("询问是否重启")
end

--- 记录本次检查时间戳，供频率门限判断。必须在发起检查**之前**写，
--- 否则检查途中失败/取消会让门限永远不生效（下次启动又立刻检查一遍）。
local function set_frequency_stamp(plugin)
    local p = prefs(plugin)
    p.attempted_at = os.time()
    save_prefs(plugin, p)
end

-- ============================================================
-- 重启 KOReader
-- ============================================================

--- 请求重启。返回是否已发出重启请求。
function UI.restart_koreader(plugin)
    local ok_can, can_restart = pcall(function() return Device:canRestart() end)
    if ok_can and can_restart == false then
        plugin:showInfo(_("当前设备不支持自动重启，请手动关闭并重新打开 KOReader 以应用更新。"))
        return false
    end

    local ok_android, is_android = pcall(function() return Device:isAndroid() end)
    if ok_android and is_android then
        plugin:showInfo(_("Android 上无法保证自动重启，请手动重新打开 KOReader 以应用更新。"))
        return false
    end

    -- 先让各模块把内存态落盘，否则重启后新版本读到的是旧设置。
    -- FlushSettings 是幂等事件，重复广播无害。
    pcall(function() UIManager:flushSettings() end)
    if type(Device.saveSettings) == "function" then
        pcall(Device.saveSettings, Device)
    end

    Log.info("[Updater] 请求重启 KOReader")
    UIManager:restartKOReader()  -- 上游入口，内部就是 quit(85)
    return true
end

-- ============================================================
-- 安装后的收尾
-- ============================================================

local function after_install(plugin, manifest)
    local version = tostring(manifest and manifest.version or "新版本")
    local mode = prefs(plugin).restart_mode or "ask"

    if mode == "auto" then
        UI.restart_koreader(plugin)
        return
    end

    if mode == "never" then
        plugin:showInfo(T(_("已安装 %1。\n\n新版本将在下次启动 KOReader 时生效。"), version))
        return
    end

    local dialog
    dialog = ButtonDialog:new{
        title = T(_("已安装 %1。\n\n当前仍运行 %2，重启 KOReader 后才会切换到新版本。"),
            version, tostring(plugin.version)),
        title_align = "center",
        buttons = {
            { {
                text = _("立即重启 KOReader"),
                callback = function()
                    UIManager:close(dialog)
                    UI.restart_koreader(plugin)
                end,
            } },
            { {
                text = _("稍后"),
                callback = function()
                    UIManager:close(dialog)
                    plugin:showInfo(T(_("新版本将在下次启动 KOReader 时生效（%1）。"), version))
                end,
            } },
        },
    }
    UIManager:show(dialog)
end

-- ============================================================
-- 下载 + 安装（子进程）
-- ============================================================

local function install_update(plugin, manifest)
    local updater = get_updater(plugin)
    local busy = T(_("正在下载 %1…"), tostring(manifest.version or ""))
    plugin:showBusy(busy)
    plugin._update_running_at = os.time()

    Async.run(
        function()
            -- download() 用 error() 报错，install() 用返回值报错，这里统一成表
            local ok_download, path_or_err = pcall(function() return updater:download(manifest) end)
            if not ok_download then
                return { ok = false, error = tostring(path_or_err) }
            end
            local installed, install_err = updater:install(path_or_err, manifest)
            if not installed then
                return { ok = false, error = tostring(install_err) }
            end
            return { ok = true }
        end,
        function(ok, result, err)
            plugin._update_running_at = nil
            plugin:closeBusy()
            if not ok or type(result) ~= "table" then
                plugin:showInfo(T(_("更新失败：\n%1"), tostring(err or "子进程异常")))
                return
            end
            if not result.ok then
                plugin:showInfo(T(_("更新失败：\n%1"), tostring(result.error or "未知原因")))
                return
            end
            after_install(plugin, manifest)
        end,
        { tag = "updater", timeout = 300 }
    )
end

-- ============================================================
-- 展示更新
-- ============================================================

local function present_update(plugin, manifest, automatic)
    if type(manifest) ~= "table" then return end

    if manifest.current then
        if not automatic then
            plugin:showInfo(T(_("当前已是最新版本（%1）"), tostring(manifest.version or plugin.version)))
        end
        return
    end

    -- 自动检查时同一个版本只提醒一次，避免每次启动都弹
    local p = prefs(plugin)
    if automatic and tostring(p.last_prompted or "") == tostring(manifest.version or "") then
        return
    end
    p.last_prompted = tostring(manifest.version or "")
    save_prefs(plugin, p)

    local text = T(_("发现新版本 %1（当前 %2）"), tostring(manifest.version or "?"), tostring(plugin.version))
    local notes = tostring(manifest.summary or manifest.notes or "")
    if notes ~= "" then
        text = text .. "\n\n" .. _("更新内容") .. "\n" .. notes
    end
    text = text .. "\n\n" .. _("是否下载并安装？")

    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("下载并安装"),
        cancel_text = _("稍后"),
        ok_callback = function() install_update(plugin, manifest) end,
    })
end

-- ============================================================
-- 检查更新
-- ============================================================

local function do_check(plugin, automatic)
    local updater = get_updater(plugin)
    if not automatic then
        plugin:showBusy(_("正在检查更新…"))
    end
    plugin._update_running_at = os.time()

    Async.run(
        function()
            local manifest, err = updater:check()
            return { manifest = manifest, error = err }
        end,
        function(ok, result, err)
            plugin._update_running_at = nil
            if not automatic then plugin:closeBusy() end

            local p = prefs(plugin)
            p.last_check = os.time()
            save_prefs(plugin, p)

            if not ok or type(result) ~= "table" then
                if not automatic then
                    plugin:showInfo(T(_("检查更新失败：\n%1"), tostring(err or "子进程异常")))
                else
                    Log.warn("[Updater] 自动检查失败：" .. tostring(err))
                end
                return
            end

            if type(result.manifest) == "table" then
                present_update(plugin, result.manifest, automatic)
            elseif not automatic then
                plugin:showInfo(T(_("检查更新失败：\n%1"), tostring(result.error or "无法读取更新清单")))
            else
                Log.warn("[Updater] 自动检查失败：" .. tostring(result.error))
            end
        end,
        { tag = "updater", timeout = 120 }
    )
end

--- 手动检查（菜单入口）。force 语义：忽略频率门限与自动开关。
function UI.check_update(plugin, force)
    if not UI.is_available() then
        plugin:showInfo(_("当前环境不支持检查更新（网络组件不可用）。"))
        return
    end
    if not is_online() then
        plugin:showInfo(_("当前没有网络连接，请连接网络后再试。"))
        return
    end
    set_frequency_stamp(plugin)
    do_check(plugin, false)
end

function UI.is_available()
    local ok, Http = pcall(require, "koobone.updater_http")
    local ok_digest, Digests = pcall(require, "koobone.digests")
    return ok and Http and Http.available() and ok_digest and Digests.available()
end

-- ============================================================
-- 自动检查（启动时调用）
-- ============================================================

--- 启动后按频率门限静默检查。force=true 时忽略门限与开关。
function UI.maybe_auto_check(plugin, force)
    if not force then
        local p = prefs(plugin)
        if p.auto_check == false then return false end
        local interval = tonumber(p.interval) or DEFAULT_INTERVAL
        local last = tonumber(p.attempted_at) or 0
        if os.time() - last < interval then return false end
    end
    if plugin._update_running_at then return false end
    if not UI.is_available() then return false end
    if not is_online() then return false end

    set_frequency_stamp(plugin)
    do_check(plugin, true)
    return true
end

-- ============================================================
-- 启动自检
-- ============================================================

-- 进程级只跑一次。KOReader 会给 FileManager 与每个 ReaderUI 各 new 一个 Plugin，
-- init 因此会被多次调用；模块级 local 在同一个 Lua VM 内是共享的，正好用来去重。
local startup_done = false

--- init 时调用一次。
function UI.startup(plugin)
    if startup_done then return end
    startup_done = true

    local updater = get_updater(plugin)
    local state, attempts = updater:startup()

    if state == "updated" then
        -- 延迟一点，等 UI 栈就绪再弹，否则可能被启动期的界面盖住
        UIManager:scheduleIn(2, function()
            plugin:showInfo(T(_("更新完成，当前版本 %1"), tostring(plugin.version)))
        end)
    elseif state == "mismatch" and (tonumber(attempts) or 0) >= 2 then
        -- 连续两次启动都没换成新版本 —— 不是「还没重启」能解释的了，提示用户
        UIManager:scheduleIn(2, function()
            plugin:showInfo(_("上次更新似乎没有生效。可在「检查更新」菜单里回滚，或重新下载安装。"))
        end)
    end

    UIManager:scheduleIn(AUTO_CHECK_DELAY, function()
        pcall(function() UI.maybe_auto_check(plugin, false) end)
    end)
end

-- ============================================================
-- 菜单
-- ============================================================

local INTERVAL_OPTIONS = {
    { 24 * 60 * 60, "每天" },
    { 3 * 24 * 60 * 60, "每 3 天" },
    { 7 * 24 * 60 * 60, "每 7 天" },
}

function UI.menu_items(plugin)
    local p = prefs(plugin)
    local items = {
        {
            text = _("立即检查更新"),
            callback = function() UI.check_update(plugin, true) end,
        },
        {
            text = _("自动检查更新"),
            checked_func = function() return prefs(plugin).auto_check ~= false end,
            keep_menu_open = true,
            callback = function()
                local np = prefs(plugin)
                np.auto_check = np.auto_check == false
                save_prefs(plugin, np)
            end,
        },
        {
            text = _("检查频率 · ") .. interval_label(p.interval),
            sub_item_table_func = function() return UI._frequency_items(plugin) end,
        },
        {
            text = _("安装完成后 · ") .. restart_label(p.restart_mode),
            sub_item_table_func = function() return UI._restart_items(plugin) end,
        },
        {
            text = T(_("当前版本 · %1"), tostring(plugin.version)),
            enabled = false,
        },
    }

    -- 只有确实留着备份时才提供回滚入口，避免菜单里长期挂一个点了会报错的项
    local backup, expected, previous = get_updater(plugin):pending_backup()
    if backup then
        table.insert(items, {
            text = T(_("回滚上次更新（回到 %1）"), tostring(previous or "?")),
            callback = function()
                local ok, err = get_updater(plugin):rollback()
                if ok then
                    plugin:showInfo(T(_("已回滚到 %1，请重启 KOReader。"), tostring(previous or "?")))
                else
                    plugin:showInfo(T(_("回滚失败：\n%1"), tostring(err)))
                end
            end,
        })
    end

    return items
end

function UI._frequency_items(plugin)
    local rows = {}
    for _, option in ipairs(INTERVAL_OPTIONS) do
        local seconds, label = option[1], option[2]
        rows[#rows + 1] = {
            text = label,
            radio = true,
            checked_func = function()
                return (tonumber(prefs(plugin).interval) or DEFAULT_INTERVAL) == seconds
            end,
            callback = function()
                local np = prefs(plugin)
                np.interval = seconds
                save_prefs(plugin, np)
            end,
        }
    end
    return rows
end

function UI._restart_items(plugin)
    local options = {
        { "ask", _("安装后询问（推荐）") },
        { "auto", _("安装后自动重启") },
        { "never", _("稍后手动重启") },
    }
    local rows = {}
    for _, option in ipairs(options) do
        local key, label = option[1], option[2]
        rows[#rows + 1] = {
            text = label,
            radio = true,
            checked_func = function()
                return (prefs(plugin).restart_mode or "ask") == key
            end,
            callback = function()
                local np = prefs(plugin)
                np.restart_mode = key
                save_prefs(plugin, np)
            end,
        }
    end
    return rows
end

return UI
