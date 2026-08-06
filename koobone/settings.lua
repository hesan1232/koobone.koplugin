local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local H = require("koobone.helper")
local Log = require("koobone.logger")

local Settings = {}
Settings.__index = Settings

local defaults = {
    auth = {
        account = "",
        password = "",
        uin = "",
        base_host = "www.koobone.com",
        cookie_vlibsid = "",
        cookie_kbskey = "",
        auto_relogin = true,
    },
    shelf = {
        sort_order = "uptime",
        per_page = 25,
    },
    cache = {
        download_covers = false,
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
        return
    end
    local cfg = self.config
    local changed = false

    -- auth 表: account / password / uin / base_host / cookie
    local auth = self.store:readSetting("auth") or deepcopy(defaults.auth)
    if (not auth.account or auth.account == "") and cfg.account then
        auth.account = cfg.account; changed = true
    end
    if (not auth.password or auth.password == "") and cfg.password then
        auth.password = cfg.password; changed = true
    end
    if (not auth.uin or auth.uin == "") and cfg.uin and cfg.uin ~= "" then
        auth.uin = cfg.uin; changed = true
    end
    if (not auth.base_host or auth.base_host == "www.koobone.com") and cfg.base_host and cfg.base_host ~= "" then
        auth.base_host = cfg.base_host; changed = true
    end
    -- cookie: 从 "VLIBSID=xxx; KBSKEY=yyy" 解析
    if (not auth.cookie_vlibsid or auth.cookie_vlibsid == "") and cfg.cookie and cfg.cookie ~= "" then
        for part in tostring(cfg.cookie):gmatch("([^;]+)") do
            local key, value = part:match("^%s*([^=]+)=(.-)%s*$")
            if key and value then
                key = H.trim(key):upper()
                value = H.trim(value)
                if key == "VLIBSID" then auth.cookie_vlibsid = value; changed = true
                elseif key == "KBSKEY" then auth.cookie_kbskey = value; changed = true end
            end
        end
    end
    if changed then self.store:saveSetting("auth", auth) end

    -- shelf 表
    local shelf = self.store:readSetting("shelf") or deepcopy(defaults.shelf)
    if cfg.shelf_sort and cfg.shelf_sort ~= shelf.sort_order then
        shelf.sort_order = cfg.shelf_sort
        self.store:saveSetting("shelf", shelf); changed = true
    end

    -- cache 表
    local cache = self.store:readSetting("cache") or deepcopy(defaults.cache)
    if cfg.download_covers ~= nil and cache.download_covers ~= cfg.download_covers then
        cache.download_covers = cfg.download_covers == true
        self.store:saveSetting("cache", cache); changed = true
    end
    if cfg.cache_max_size_mb and cache.cache_max_size_mb ~= cfg.cache_max_size_mb then
        cache.cache_max_size_mb = cfg.cache_max_size_mb
        self.store:saveSetting("cache", cache); changed = true
    end

    -- reader 表
    local reader = self.store:readSetting("reader") or deepcopy(defaults.reader)
    if cfg.pre_download_pages and reader.pre_download_pages ~= cfg.pre_download_pages then
        reader.pre_download_pages = cfg.pre_download_pages
        self.store:saveSetting("reader", reader); changed = true
    end
    if cfg.progress_upload_interval and reader.progress_upload_interval ~= cfg.progress_upload_interval then
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
        return nil
    end

    local file = io.open(self.config_path, "r")
    if not file then
        Log.debug("config.lua 不存在，使用默认配置")
        return nil
    end
    file:close()

    local ok, config = pcall(dofile, self.config_path)
    if not ok or type(config) ~= "table" then
        Log.error("config.lua 加载失败: " .. tostring(config))
        return nil
    end

    Log.info("config.lua 加载成功")
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

function Settings:get_account()
    return self:get("auth") and self:get("auth").account or ""
end

function Settings:set_account(v)
    local auth = self:get("auth") or {}
    auth.account = v or ""
    self:set("auth", auth)
end

function Settings:get_password()
    return self:get("auth") and self:get("auth").password or ""
end

function Settings:set_password(v)
    local auth = self:get("auth") or {}
    auth.password = v or ""
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
    return self:get("auth") and self:get("auth").base_host or "www.koobone.com"
end

function Settings:set_base_host(v)
    local auth = self:get("auth") or {}
    auth.base_host = v or "www.koobone.com"
    self:set("auth", auth)
end

function Settings:get_cookie()
    local auth = self:get("auth") or {}
    local parts = {}
    if auth.cookie_vlibsid and auth.cookie_vlibsid ~= "" then
        table.insert(parts, "VLIBSID=" .. auth.cookie_vlibsid)
    end
    if auth.cookie_kbskey and auth.cookie_kbskey ~= "" then
        table.insert(parts, "KBSKEY=" .. auth.cookie_kbskey)
    end
    return table.concat(parts, "; ")
end

function Settings:set_cookie(cookie_str)
    cookie_str = cookie_str or ""
    local auth = self:get("auth") or {}
    auth.cookie_vlibsid = ""
    auth.cookie_kbskey = ""
    for part in cookie_str:gmatch("([^;]+)") do
        local key, value = part:match("^%s*([^=]+)=(.-)%s*$")
        if key and value then
            key = H.trim(key):upper()
            value = H.trim(value)
            if key == "VLIBSID" then
                auth.cookie_vlibsid = value
            elseif key == "KBSKEY" then
                auth.cookie_kbskey = value
            end
        end
    end
    self:set("auth", auth)
end

function Settings:is_auto_relogin()
    return self:get("auth") and self:get("auth").auto_relogin ~= false
end

function Settings:set_auto_relogin(v)
    local auth = self:get("auth") or {}
    auth.auto_relogin = v == true
    self:set("auth", auth)
end

function Settings:get_shelf_sort()
    return self:get("shelf") and self:get("shelf").sort_order or "uptime"
end

function Settings:set_shelf_sort(v)
    local shelf = self:get("shelf") or {}
    shelf.sort_order = v or "uptime"
    self:set("shelf", shelf)
end

function Settings:should_download_covers()
    return self:get("cache") and self:get("cache").download_covers == true
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

    -- 辅助函数：执行登录
    local function do_login(account, password, base_host)
        if not (plugin and plugin.auth) then
            show_info(_("认证模块未初始化"))
            return
        end
        if account == "" or password == "" then
            show_info(_("请先填写账号和密码"))
            return
        end
        local execute = function()
            local ok_call, login_ok, msg = pcall(function()
                return plugin.auth:login(account, password, base_host)
            end)
            if not ok_call then
                show_info(_("登录异常: ") .. tostring(login_ok))
            elseif login_ok then
                self:flush()
                show_info(msg or _("登录成功"))
            else
                show_info(msg or _("登录失败"))
            end
        end
        show_info(_("正在登录..."))
        if ok_ui and UIManager.scheduleIn then
            UIManager:scheduleIn(0.05, execute)
        else
            execute()
        end
    end

    -- 辅助函数：测试 Cookie
    local function do_test_cookie()
        if not (plugin and plugin.auth) then
            show_info(_("认证模块未初始化"))
            return
        end
        local cookie = self:get_cookie()
        if cookie == "" then
            show_info(_("Cookie 为空，请先登录或填写 Cookie"))
            return
        end
        local execute = function()
            local ok_call, test_ok, msg = pcall(function()
                return plugin.auth:test_cookie(cookie)
            end)
            if not ok_call then
                show_info(_("测试异常: ") .. tostring(test_ok))
            elseif test_ok then
                show_info(msg or _("Cookie 有效"))
            else
                show_info(msg or _("Cookie 失效"))
            end
        end
        show_info(_("正在测试 Cookie..."))
        if ok_ui and UIManager.scheduleIn then
            UIManager:scheduleIn(0.05, execute)
        else
            execute()
        end
    end

    return {
        -- ========== 账号设置 ==========
        {
            text = _("账号设置"),
            sub_item_table = {
                {
                    text = _("账号 (邮箱)"),
                    callback = function()
                        input_dialog(
                            _("账号 (邮箱)"),
                            _("请输入邮箱账号"),
                            self:get_account(),
                            false,
                            function(value)
                                self:set_account(value)
                                self:flush()
                                show_info(_("账号已保存"))
                            end
                        )
                    end,
                },
                {
                    text = _("密码"),
                    callback = function()
                        input_dialog(
                            _("密码"),
                            _("请输入密码"),
                            self:get_password(),
                            true,
                            function(value)
                                self:set_password(value)
                                self:flush()
                                show_info(_("密码已保存"))
                            end
                        )
                    end,
                },
                {
                    text = _("网站地址"),
                    callback = function()
                        input_dialog(
                            _("网站地址"),
                            _("例如: www.koobone.com 或 https://koobone.com"),
                            self:get_base_host(),
                            false,
                            function(value)
                                self:set_base_host(value)
                                self:flush()
                                show_info(_("网站地址已保存"))
                            end
                        )
                    end,
                },
                {
                    text = _("登录"),
                    callback = function()
                        do_login(self:get_account(), self:get_password(), self:get_base_host())
                    end,
                },
            },
        },
        -- ========== 下载设置 ==========
        {
            text = _("下载设置"),
            sub_item_table = {
                {
                    text = _("预下载章节数"),
                    callback = function()
                        input_dialog(
                            _("预下载章节数"),
                            _("阅读时提前下载后 N 章 (0 表示不预下载)"),
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
                    },
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
