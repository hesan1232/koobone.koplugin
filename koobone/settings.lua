local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local H = require("koobone.helper")
local Log = require("koobone.logger")
local Koobone = require("koobone.koobone")

local Settings = {}
Settings.__index = Settings

local defaults = {
    auth = {
        api_key = "",
        uin = "",
        base_host = Koobone.DEFAULT_HOST,
    },
    shelf = {
        sort_order = "last_read",
        per_page = 25,
    },
    cache = {
        download_covers = true,
        cache_max_size_mb = 1024,
        lru_cleanup_enabled = true,
    },
    reader = {
        pre_download_pages = 3,
        progress_upload_interval = 60,
        auto_pull_progress = true,
    },
    advanced = {
        developer_logs = false,
    },
}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    setmetatable(out, getmetatable(value))
    return out
end

local function merge_tables(default, override)
    local result = deepcopy(default)
    if type(override) ~= "table" then
        return result
    end
    for key, value in pairs(override) do
        if type(value) == "table" and type(result[key]) == "table" then
            result[key] = merge_tables(result[key], value)
        else
            result[key] = value
        end
    end
    return result
end

function Settings:new()
    local data_dir = H.get_data_dir()
    H.make_dir(data_dir)

    local obj = {
        data_dir = data_dir,
        settings_file = DataStorage:getSettingsDir() .. "/koobone.lua",
        config = nil,
        config_path = nil,
    }
    obj.store = LuaSettings:open(obj.settings_file)

    setmetatable(obj, self)

    obj.config_path = obj:_get_config_path()
    obj.config = obj:_load_config_file()

    if not obj.store:has("auth") then
        obj.store:saveSetting("auth", deepcopy(defaults.auth))
        obj.store:saveSetting("shelf", deepcopy(defaults.shelf))
        obj.store:saveSetting("cache", deepcopy(defaults.cache))
        obj.store:saveSetting("reader", deepcopy(defaults.reader))
        obj.store:saveSetting("advanced", deepcopy(defaults.advanced))
        obj.store:flush()
    end

    -- 修复: config.lua 使用扁平 key（account/password/base_host/...），
    -- 但 store 使用嵌套结构（auth.account/auth.password/...）。
    -- 之前 Settings:get 只在 store 结果为 nil 时回退 config，但 store 已有
    -- 默认 auth 表（空 account），所以 config 永远不会被读取。
    -- 这里将 config 的扁平 key 合并到 store 的嵌套结构，仅当 store 值为空/默认时。
    obj:_merge_config()

    return obj
end

function Settings:_merge_config()
    if not self.config or type(self.config) ~= "table" then
        Log.warn("_merge_config: config 为空，跳过合并（config.lua 未加载或加载失败）")
        return
    end
    local cfg = self.config
    local changed = false

    -- auth 表: api_key / uin / base_host
    local auth = self.store:readSetting("auth") or deepcopy(defaults.auth)
    -- 诊断: 记录 api_key 合并决策
    local store_api_key = auth.api_key or ""
    local cfg_api_key = cfg.api_key or ""
    if store_api_key == "" and cfg_api_key ~= "" then
        Log.info("合并 api_key: 从 config.lua 写入 store（store 原为空）")
        auth.api_key = cfg.api_key; changed = true
    elseif store_api_key ~= "" and cfg_api_key ~= "" and store_api_key ~= cfg_api_key then
        Log.info("跳过合并 api_key: store 已有值（以 UI 设置为准），不覆盖 config.lua 的值")
    elseif store_api_key == "" and cfg_api_key == "" then
        Log.warn("api_key 均为空: config.lua 和 store 都没有 api_key，请在 Koobone 设置中填写")
    end
    if (not auth.uin or auth.uin == "") and cfg.uin and cfg.uin ~= "" then
        auth.uin = cfg.uin; changed = true
    end
    if (not auth.base_host or auth.base_host == Koobone.DEFAULT_HOST) and cfg.base_host and cfg.base_host ~= "" then
        auth.base_host = cfg.base_host; changed = true
    end
    if changed then self.store:saveSetting("auth", auth) end

    -- shelf 表: nil-only 合并（只在 store 值为空时才从 config 读取）
    -- 修复: 之前逻辑是"config 值和 store 值不同就覆盖"，导致用户在界面中
    -- 设置的排序每次重启都被 config.lua 的 shelf_sort 覆盖回去
    local shelf = self.store:readSetting("shelf") or deepcopy(defaults.shelf)
    if (not shelf.sort_order or shelf.sort_order == "") and cfg.shelf_sort then
        shelf.sort_order = cfg.shelf_sort
        self.store:saveSetting("shelf", shelf); changed = true
    end

    -- cache 表: nil-only 合并
    local cache = self.store:readSetting("cache") or deepcopy(defaults.cache)
    if cache.download_covers == nil and cfg.download_covers ~= nil then
        cache.download_covers = cfg.download_covers == true
        self.store:saveSetting("cache", cache); changed = true
    end
    if (not cache.cache_max_size_mb) and cfg.cache_max_size_mb then
        cache.cache_max_size_mb = cfg.cache_max_size_mb
        self.store:saveSetting("cache", cache); changed = true
    end

    -- reader 表: nil-only 合并
    local reader = self.store:readSetting("reader") or deepcopy(defaults.reader)
    if (not reader.pre_download_pages) and cfg.pre_download_pages then
        reader.pre_download_pages = cfg.pre_download_pages
        self.store:saveSetting("reader", reader); changed = true
    end
    if (not reader.progress_upload_interval) and cfg.progress_upload_interval then
        reader.progress_upload_interval = cfg.progress_upload_interval
        self.store:saveSetting("reader", reader); changed = true
    end

    if changed then
        Log.info("config.lua 值已合并到 store")
        pcall(function() self.store:flush() end)
    end
end

function Settings:_get_config_path()
    local source = debug.getinfo(1, "S").source or ""
    local path = source:match("^@(.+)$") or source
    local plugin_dir = path:match("^(.*)[/\\][^/\\]+$") or "."
    plugin_dir = plugin_dir:match("^(.*)[/\\][^/\\]+$") or plugin_dir
    return plugin_dir .. "/config.lua"
end

function Settings:_load_config_file()
    if not self.config_path then
        Log.warn("config_path 为空，config.lua 不会被加载")
        return nil
    end

    local file = io.open(self.config_path, "r")
    if not file then
        Log.warn("config.lua 不存在: " .. self.config_path .. "（API Key 等配置将不会被读取）")
        return nil
    end
    file:close()

    local ok, config = pcall(dofile, self.config_path)
    if not ok or type(config) ~= "table" then
        Log.error("config.lua 加载失败: " .. self.config_path .. " - " .. tostring(config))
        return nil
    end

    -- 诊断: 记录关键字段是否存在于 config.lua
    local has_api_key = config.api_key ~= nil and config.api_key ~= ""
    Log.info("config.lua 加载成功: " .. self.config_path
        .. " | api_key=" .. (has_api_key and "已配置" or "缺失或为空"))
    return config
end

function Settings:get(key, default_fallback)
    local default_value = defaults[key]
    if default_fallback ~= nil then
        default_value = default_fallback
    end

    local result = self.store:readSetting(key, nil)

    if result == nil and self.config and self.config[key] ~= nil then
        result = deepcopy(self.config[key])
    end

    if result == nil then
        result = deepcopy(default_value)
    end

    return result
end

function Settings:set(key, value)
    Log.debug("设置 " .. key .. ": " .. tostring(value))
    self.store:saveSetting(key, value)
end

function Settings:flush()
    Log.debug("刷新设置到文件: " .. self.settings_file)
    local ok, err = pcall(function()
        self.store:flush()
    end)
    if ok then
        Log.debug("设置刷新成功")
    else
        Log.error("设置刷新失败: " .. tostring(err))
    end
end

function Settings:get_api_key()
    return self:get("auth") and self:get("auth").api_key or ""
end

function Settings:set_api_key(v)
    local auth = self:get("auth") or {}
    auth.api_key = v or ""
    self:set("auth", auth)
end

function Settings:get_uin()
    return self:get("auth") and self:get("auth").uin or ""
end

function Settings:set_uin(v)
    local auth = self:get("auth") or {}
    auth.uin = v or ""
    self:set("auth", auth)
end

function Settings:get_base_host()
    return self:get("auth") and self:get("auth").base_host or Koobone.DEFAULT_HOST
end

function Settings:set_base_host(v)
    local auth = self:get("auth") or {}
    auth.base_host = v or Koobone.DEFAULT_HOST
    self:set("auth", auth)
end

function Settings:get_shelf_sort()
    local shelf = self:get("shelf")
    return (shelf and shelf.sort_order) or "last_read"
end

function Settings:set_shelf_sort(v)
    local shelf = self:get("shelf") or {}
    shelf.sort_order = v or "last_read"
    self:set("shelf", shelf)
end

-- 下载任务持久化（异常退出重启后恢复/标记中断）
function Settings:getDownloadTask()
    return self:get("download_task")
end

function Settings:setDownloadTask(task)
    self:set("download_task", task)
end

-- 下载历史（最近10条）
function Settings:getDownloadHistory()
    return self:get("download_history")
end

function Settings:setDownloadHistory(history)
    self:set("download_history", history)
end

function Settings:should_download_covers()
    local cache = self:get("cache") or {}
    -- cache.download_covers: true=下载, false=不下载, nil=默认下载（兼容旧缓存无此字段）
    return cache.download_covers ~= false
end

function Settings:set_download_covers(v)
    local cache = self:get("cache") or {}
    cache.download_covers = v == true
    self:set("cache", cache)
end

function Settings:get_cache_max_mb()
    return self:get("cache") and self:get("cache").cache_max_size_mb or 1024
end

function Settings:get_pre_download_chapters()
    return self:get("reader") and self:get("reader").pre_download_pages or 0
end

function Settings:set_pre_download_chapters(n)
    local reader = self:get("reader") or {}
    reader.pre_download_pages = tonumber(n) or 0
    self:set("reader", reader)
end

function Settings:get_progress_upload_interval()
    return self:get("reader") and self:get("reader").progress_upload_interval or 60
end

function Settings:is_auto_pull_progress()
    return self:get("reader") and self:get("reader").auto_pull_progress ~= false
end

function Settings:should_show_debug_logs()
    return self:get("advanced") and self:get("advanced").developer_logs == true
end

function Settings:build_menu_items(plugin)
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local ok_input, InputDialog = pcall(require, "ui/widget/inputdialog")
    local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
    local ok_confirm, ConfirmBox = pcall(require, "ui/widget/confirmbox")
    local ok_multiinput, MultiInputDialog = pcall(require, "ui/widget/multiinputdialog")

    -- 修复: require("gettext") 可能加载失败导致整个 build_menu_items 抛错
    local ok_gettext, gettext = pcall(require, "gettext")
    local _ = (ok_gettext and gettext) or function(text) return text end

    local function show_info(text)
        if ok_ui and ok_info then
            UIManager:show(InfoMessage:new{ text = text })
        end
    end

    -- 菜单 close_callback 为空函数，点击叶子节点后菜单不关闭，
    -- InputDialog 弹出时菜单在后台保留，输入完成后菜单恢复可见。
    -- 所以不需要 reopen_settings 逻辑。

    local function input_dialog(title, input_hint, default_value, is_password, callback)
        if not (ok_ui and ok_input) then
            return
        end
        -- 修复: 预声明 input 变量让闭包正确捕获；
        -- 用 pcall 包裹 UIManager:close 防止 handleEvent nil 导致闪退
        local input
        input = InputDialog:new{
            title = title,
            input_hint = input_hint,
            input = default_value or "",
            is_password = is_password == true,
            buttons = {
                {
                    {
                        text = _("取消"),
                        callback = function()
                            pcall(function() UIManager:close(input) end)
                        end,
                    },
                    {
                        text = _("确定"),
                        is_enter_default = true,
                        callback = function()
                            local value = nil
                            pcall(function() value = input:getInputText() end)
                            pcall(function() UIManager:close(input) end)
                            if callback then
                                callback(value or "")
                            end
                        end,
                    },
                },
            },
        }
        UIManager:show(input)
        -- 确保键盘弹出（部分 KOReader 版本需要显式调用）
        if input and input.onShowKeyboard then
            pcall(function() input:onShowKeyboard() end)
        end
    end

    local function confirm_dialog(title, content, ok_callback)
        if not (ok_ui and ok_confirm) then
            if ok_callback then ok_callback() end
            return
        end
        UIManager:show(ConfirmBox:new{
            text = content,
            ok_text = _("确定"),
            cancel_text = _("取消"),
            ok_callback = function()
                if ok_callback then
                    ok_callback()
                end
            end,
        })
    end

    local function delete_dir_contents(dir_path)
        if not H.dir_exists(dir_path) then
            return 0
        end
        local lfs = require("libs/libkoreader-lfs")
        local count = 0
        for entry in lfs.dir(dir_path) do
            if entry ~= "." and entry ~= ".." then
                local full_path = H.join_path(dir_path, entry)
                local mode = lfs.attributes(full_path, "mode")
                if mode == "directory" then
                    H.delete_dir(full_path)
                else
                    H.delete_file(full_path)
                end
                count = count + 1
            end
        end
        return count
    end

    -- 辅助函数：保存 API Key（api_key 直传鉴权，无需校验 sess_key）
    local function do_save_api_key(api_key)
        if api_key == "" then
            show_info(_("API Key 已清空"))
            return
        end
        self:set_api_key(api_key)
        self:flush()
        show_info(_("API Key 已保存"))
    end

    -- API Key 设置对话框：个人页面获取的 X-KB-INFO 凭据
    local function api_key_dialog()
        input_dialog(
            _("API Key 设置"),
            _("请输入个人页面获取的 API Key"),
            self:get_api_key(),
            false,
            function(value)
                value = H.trim(value)
                do_save_api_key(value)
            end
        )
    end

    return {
        -- ========== API Key 设置 ==========
        {
            text = _("API Key 设置"),
            callback = function()
                api_key_dialog()
            end,
        },
        -- ========== 下载设置 ==========
        {
            text = _("下载设置"),
            sub_item_table = {
                {
                    text = _("预下载卷数"),
                    callback = function()
                        input_dialog(
                            _("预下载卷数"),
                            _("阅读时提前下载后 N 卷 (0 表示不预下载)"),
                            tostring(self:get_pre_download_chapters()),
                            false,
                            function(value)
                                local n = tonumber(value)
                                if n and n >= 0 then
                                    self:set_pre_download_chapters(n)
                                    self:flush()
                                    show_info(_("预下载设置已保存"))
                                else
                                    show_info(_("请输入有效数字"))
                                end
                            end
                        )
                    end,
                },
                {
                    text = _("排序方式"),
                    sub_item_table = {
                        {
                            text = _("按更新时间"),
                            checked_func = function()
                                return self:get_shelf_sort() == "uptime"
                            end,
                            callback = function()
                                self:set_shelf_sort("uptime")
                                self:flush()
                            end,
                        },
                        {
                            text = _("按漫画名称"),
                            checked_func = function()
                                return self:get_shelf_sort() == "vol_name"
                            end,
                            callback = function()
                                self:set_shelf_sort("vol_name")
                                self:flush()
                            end,
                        },
                        {
                            text = _("按最后阅读"),
                            checked_func = function()
                                return self:get_shelf_sort() == "last_read"
                            end,
                            callback = function()
                                self:set_shelf_sort("last_read")
                                self:flush()
                            end,
                        },
                    },
                },
                {
                    text = _("下载封面"),
                    checked_func = function()
                        return self:should_download_covers()
                    end,
                    callback = function()
                        self:set_download_covers(not self:should_download_covers())
                        self:flush()
                        show_info(self:should_download_covers()
                            and _("已开启封面下载，下次打开书架会自动下载封面")
                            or _("已关闭封面下载"))
                    end,
                },
                {
                    text = _("清除所有缓存"),
                    callback = function()
                        confirm_dialog(
                            _("清除所有缓存"),
                            _("确定要清除封面和 EPUB 缓存吗？"),
                            function()
                                local c1 = delete_dir_contents(H.get_covers_dir())
                                local c2 = delete_dir_contents(H.get_epub_dir())
                                show_info(string.format(_("已清除封面 %d 个, EPUB %d 个"), c1, c2))
                            end
                        )
                    end,
                },
            },
        },
        -- ========== 同步设置 ==========
        {
            text = _("同步设置"),
            sub_item_table = {
                {
                    text = _("进度上传间隔(秒)"),
                    callback = function()
                        input_dialog(
                            _("进度上传间隔(秒)"),
                            _("请输入秒数 (0 表示关闭)"),
                            tostring(self:get_progress_upload_interval()),
                            false,
                            function(value)
                                local n = tonumber(value)
                                if n and n >= 0 then
                                    local reader = self:get("reader") or {}
                                    reader.progress_upload_interval = n
                                    self:set("reader", reader)
                                    self:flush()
                                    show_info(_("上传间隔已保存"))
                                else
                                    show_info(_("请输入有效数字"))
                                end
                            end
                        )
                    end,
                },
                {
                    text = _("进入时自动拉取进度"),
                    checked_func = function()
                        return self:is_auto_pull_progress()
                    end,
                    callback = function()
                        local reader = self:get("reader") or {}
                        reader.auto_pull_progress = not reader.auto_pull_progress
                        self:set("reader", reader)
                        self:flush()
                    end,
                },
            },
        },
        -- ========== 关于 ==========
        {
            text = _("关于"),
            sub_item_table = {
                {
                    text = _("查看日志"),
                    callback = function()
                        local log_path = Log.get_log_file_path()
                        show_info(string.format(_("日志文件路径:\n%s"), log_path))
                    end,
                },
                {
                    text = _("调试日志"),
                    checked_func = function()
                        return self:should_show_debug_logs()
                    end,
                    callback = function()
                        local advanced = self:get("advanced") or {}
                        advanced.developer_logs = not advanced.developer_logs
                        self:set("advanced", advanced)
                        self:flush()
                    end,
                },
                {
                    text = _("Koobone 插件 v0.3.0"),
                    enabled = false,
                    callback = function() end,
                },
            },
        },
    }
end

return Settings
