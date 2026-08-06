local Log = require("koobone.logger")
local H = require("koobone.helper")
local Cookie = require("koobone.cookie")

local ok_client, Client = pcall(require, "koobone.client")
if not ok_client then
    Log.warn("auth.lua: koobone.client 模块暂不可用，登录功能将受限")
    Client = nil
end

local Auth = {}
Auth.__index = Auth

local DEFAULT_HOST = "www.koobone.com"
local BOUNDARY = "----WebKitFormBoundaryForKoobone"
local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

local function header_value(headers, name)
    if not headers then return nil end
    local target = name:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == target then
            return value
        end
    end
    return nil
end

local function ltn12_source_string(s)
    local ltn12_ok, ltn12 = pcall(require, "ltn12")
    if ltn12_ok and ltn12 and ltn12.source then
        return ltn12.source.string(s)
    end
    return nil
end

local function ltn12_sink_table(t)
    local ltn12_ok, ltn12 = pcall(require, "ltn12")
    if ltn12_ok and ltn12 and ltn12.sink then
        return ltn12.sink.table(t)
    end
    return nil
end

function Auth:new(settings)
    local obj = setmetatable({
        settings = settings,
        cookie = Cookie:new(),
    }, self)
    obj:load_from_settings()
    return obj
end

function Auth:load_from_settings()
    if not self.settings then return end
    local store = self.settings
    -- 修复: 统一使用 Settings 的标准 getter（读取 auth 嵌套表），
    -- 而非顶层 "account"/"koobone_cookie_vlibsid" 等旧 key。
    -- 这样 Auth 保存的数据和 Settings UI 读写的数据完全一致。
    if store.get_account then
        self.account = store:get_account() or ""
        self.password = store:get_password() or ""
        self.uin = store:get_uin() or ""
        self.base_host = store:get_base_host() or DEFAULT_HOST
    elseif store.get then
        -- 兼容: 直接从 auth 表读取
        local auth_tbl = store:get("auth") or {}
        self.account = auth_tbl.account or ""
        self.password = auth_tbl.password or ""
        self.uin = tostring(auth_tbl.uin or "")
        self.base_host = auth_tbl.base_host or DEFAULT_HOST
    end
    -- Cookie: 优先用 Settings:get_cookie（从 auth 表读取），兼容旧的顶层 key
    if store.get_cookie then
        local cookie_str = store:get_cookie()
        if cookie_str and cookie_str ~= "" then
            self.cookie = Cookie.from_string(cookie_str)
            Log.debug("Auth: 从 auth 表加载 Cookie 成功")
        end
    end
    if not self.cookie:is_valid() then
        -- 回退: 尝试旧的顶层存储路径（迁移用）
        self.cookie:load_from_settings(store, "koobone_")
        self.cookie:load_from_settings(store, "")
        if self.cookie:is_valid() then
            Log.info("Auth: 从旧路径迁移 Cookie 到 auth 表")
            self:save_to_settings()
        end
    end
end

function Auth:save_to_settings()
    if not self.settings then return false end
    local store = self.settings
    -- 修复: 统一使用 Settings 的标准 setter（写入 auth 嵌套表），
    -- 与 Settings UI 的 set_account/set_cookie 保持同一存储位置。
    local ok, err = pcall(function()
        if store.set_account then
            store:set_account(self.account or "")
            store:set_password(self.password or "")
            store:set_uin(self.uin or "")
            if self.base_host and self.base_host ~= "" then
                store:set_base_host(self.base_host)
            end
        elseif store.set then
            -- 兼容: 直接写 auth 表
            local auth_tbl = store:get("auth") or {}
            auth_tbl.account = self.account or ""
            auth_tbl.password = self.password or ""
            auth_tbl.uin = tostring(self.uin or "")
            if self.base_host and self.base_host ~= "" then
                auth_tbl.base_host = self.base_host
            end
            store:set("auth", auth_tbl)
        end
        -- Cookie 写入 auth 表
        if store.set_cookie then
            store:set_cookie(self.cookie:to_header_string())
        end
    end)
    if not ok then
        Log.warn("Auth: save_to_settings 失败: " .. tostring(err))
        return false
    end
    if store.flush then
        pcall(function() store:flush() end)
    end
    return true
end

function Auth:resolve_host(base_host)
    base_host = H.trim(base_host or self.base_host or DEFAULT_HOST)
    if base_host == "" then
        base_host = DEFAULT_HOST
    end
    if base_host:find("^http://") == 1 or base_host:find("^https://") == 1 then
        local scheme, hostpart = base_host:match("^(https?)://([^/]+)")
        if scheme and hostpart then
            local is_https = scheme == "https"
            local target_host = hostpart
            local port
            local colon_pos = hostpart:find(":", 1, true)
            if colon_pos then
                target_host = hostpart:sub(1, colon_pos - 1)
                local port_str = hostpart:sub(colon_pos + 1)
                port = tonumber(port_str) or (is_https and 443 or 80)
            else
                port = is_https and 443 or 80
            end
            return target_host, is_https, port, base_host
        end
    end
    local target_host = base_host
    local port
    local colon_pos = base_host:find(":", 1, true)
    if colon_pos then
        target_host = base_host:sub(1, colon_pos - 1)
        local port_str = base_host:sub(colon_pos + 1)
        port = tonumber(port_str)
    end
    local is_local = target_host == "127.0.0.1" or target_host == "localhost"
    local is_https = not is_local
    if not port then
        port = is_https and 443 or 80
    end
    local normalized
    if is_https then
        normalized = "https://" .. target_host
        if port ~= 443 then normalized = normalized .. ":" .. port end
    else
        normalized = "http://" .. target_host
        if port ~= 80 then normalized = normalized .. ":" .. port end
    end
    return target_host, is_https, port, normalized
end

local function build_multipart_body(fields)
    local lines = {}
    for _, f in ipairs(fields) do
        table.insert(lines, "--" .. BOUNDARY)
        table.insert(lines, string.format('Content-Disposition: form-data; name="%s"', f.name))
        table.insert(lines, "")
        table.insert(lines, tostring(f.value))
    end
    table.insert(lines, "--" .. BOUNDARY .. "--")
    table.insert(lines, "")
    return table.concat(lines, "\r\n")
end

function Auth:_http_request(opts)
    if Client and Client.new then
        local client_instance
        if type(Client.new) == "function" then
            client_instance = Client:new(self.settings)
        else
            client_instance = Client
        end
        if client_instance and client_instance.request then
            local ok, text, code, resp_headers = pcall(function()
                return client_instance:request(opts)
            end)
            if ok then
                return text, code, resp_headers
            end
            Log.warn("Auth: client.request 异常: " .. tostring(text))
        end
    end
    local url = opts.url
    local method = opts.method or (opts.body and "POST" or "GET")
    local headers = opts.headers or {}
    local body = opts.body
    local timeout = opts.timeout or 30
    headers["User-Agent"] = headers["User-Agent"] or USER_AGENT
    headers["Accept"] = headers["Accept"] or "application/json, text/plain, */*"
    headers["Accept-Encoding"] = "identity"
    headers["Connection"] = "keep-alive"
    if body then
        headers["Content-Length"] = tostring(#body)
    end
    local is_https = url:find("^https:") == 1
    local transport
    if is_https then
        local ok_ssl, ssl = pcall(require, "ssl.https")
        if ok_ssl then
            transport = ssl
        end
    else
        local ok_http, http = pcall(require, "socket.http")
        if ok_http then
            transport = http
        end
    end
    if not transport then
        return nil, nil, nil, (is_https and "ssl.https" or "socket.http") .. " 不可用"
    end
    local response_chunks = {}
    local prev_timeout = transport.TIMEOUT
    transport.TIMEOUT = timeout
    local source = body and ltn12_source_string(body) or nil
    local sink = ltn12_sink_table(response_chunks)
    local ok, result1, result2, result3 = pcall(transport.request, {
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = sink,
    })
    transport.TIMEOUT = prev_timeout
    if not ok then
        return nil, nil, nil, tostring(result1)
    end
    if result1 == nil and type(result2) == "string" then
        return nil, nil, nil, tostring(result2)
    end
    local text = table.concat(response_chunks)
    local code = tonumber(result2)
    local resp_headers = result3 or {}
    return text, code, resp_headers, nil
end

function Auth:login(account, password, base_host_opt)
    account = H.trim(account or self.account or "")
    password = H.trim(password or self.password or "")
    local base_host = H.trim(base_host_opt or self.base_host or DEFAULT_HOST)
    if #account < 6 then
        return false, "请填写正确的账号邮箱（至少 6 位）", nil
    end
    if #password < 4 then
        return false, "请填写正确的密码（至少 4 位）", nil
    end
    local target_host, is_https, port, normalized = self:resolve_host(base_host)
    local scheme = is_https and "https" or "http"
    local origin_base = normalized
    local form_body = build_multipart_body({
        { name = "email", value = account },
        { name = "passwd", value = password },
        { name = "keepalive", value = "1" },
    })
    local xkb_from = "KOOBONE/5.0.0 POST /login.php"
    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
        ["Referer"] = origin_base .. "/login.php?goto=web.htm",
        ["Origin"] = origin_base,
        ["X-Requested-With"] = "XMLHttpRequest",
        ["X-KB-FROM"] = xkb_from,
        ["Content-Type"] = "multipart/form-data; boundary=" .. BOUNDARY,
    }
    local request_url
    if port == 443 and is_https then
        request_url = "https://" .. target_host .. "/login_do.php"
    elseif port == 80 and not is_https then
        request_url = "http://" .. target_host .. "/login_do.php"
    else
        request_url = scheme .. "://" .. target_host .. ":" .. port .. "/login_do.php"
    end
    Log.info("Auth: 登录请求 " .. request_url .. " account=" .. account)
    local text, code, resp_headers, err = self:_http_request({
        url = request_url,
        method = "POST",
        headers = headers,
        body = form_body,
        timeout = 30,
    })
    if err or not code then
        Log.error("Auth: 登录连接失败: " .. tostring(err or "未知错误"))
        return false, "连接 koobone 登录接口失败: " .. tostring(err or "未知错误"), nil
    end
    Log.debug("Auth: 登录响应 code=" .. tostring(code) .. " len=" .. tostring(#(text or "")))
    local resp_json = H.json_decode(text)
    local uin = nil
    local msg = ""
    if type(resp_json) == "table" then
        uin = resp_json.uin or resp_json.Uin or resp_json.uid
        msg = resp_json.msg or resp_json.message or ""
    end
    self.cookie:clear()
    local sc = header_value(resp_headers, "set-cookie")
    if sc then
        self.cookie:parse_set_cookie(sc)
    end
    local cookie_captured = self.cookie:is_valid()
    if not cookie_captured and type(resp_json) == "table" then
        for _, k in ipairs({"cookie", "Cookie", "session", "cookies"}) do
            local v = resp_json[k]
            if v and type(v) == "string" and v:find("=", 1, true) then
                local temp = Cookie.from_string(v)
                if temp:get("VLIBSID") then self.cookie:set("VLIBSID", temp:get("VLIBSID")) end
                if temp:get("KBSKEY") then self.cookie:set("KBSKEY", temp:get("KBSKEY")) end
                Log.debug("Auth: 从 JSON 回退字段提取 Cookie: " .. k)
                break
            end
        end
    end
    cookie_captured = self.cookie:is_valid()
    local data = {
        status = code,
        uin = uin,
        msg = msg,
        cookieCaptured = cookie_captured,
        cookieSaved = false,
    }
    if not uin then
        local err_msg = msg ~= "" and msg or "账号或密码错误"
        Log.warn("Auth: 登录失败, uin 为空, msg=" .. err_msg)
        data.msg = err_msg
        return false, err_msg, data
    end
    self.account = account
    self.password = password
    self.uin = tostring(uin)
    self.base_host = base_host
    if cookie_captured then
        self:save_to_settings()
        data.cookieSaved = true
        Log.info("Auth: 登录成功 uin=" .. tostring(uin) .. " cookie 已保存")
    else
        Log.warn("Auth: 登录成功 uin=" .. tostring(uin) .. " 但未捕获到有效 Cookie")
    end
    return true, msg ~= "" and msg or ("登录成功 uin=" .. tostring(uin)), data
end

function Auth:test_cookie(cookie_str, base_host_opt)
    cookie_str = H.trim(cookie_str or self.cookie:to_header_string())
    local base_host = H.trim(base_host_opt or self.base_host or DEFAULT_HOST)
    if cookie_str == "" then
        return false, "Cookie 未配置", nil
    end
    local target_host, is_https, port, normalized = self:resolve_host(base_host)
    local request_url
    if port == 443 and is_https then
        request_url = "https://" .. target_host .. "/"
    elseif port == 80 and not is_https then
        request_url = "http://" .. target_host .. "/"
    else
        local scheme = is_https and "https" or "http"
        request_url = scheme .. "://" .. target_host .. ":" .. port .. "/"
    end
    local headers = {
        ["User-Agent"] = USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
        ["Cookie"] = cookie_str,
        ["Referer"] = normalized .. "/",
    }
    Log.debug("Auth: 测试 Cookie -> " .. request_url)
    local text, code, resp_headers, err = self:_http_request({
        url = request_url,
        method = "GET",
        headers = headers,
        timeout = 20,
    })
    if err or not code then
        return false, "连接失败: " .. tostring(err or "未知错误"), { status = code }
    end
    local data = {
        status = code,
        length = #(text or ""),
    }
    if code >= 200 and code < 400 then
        return true, "连接成功 HTTP " .. tostring(code), data
    end
    return false, "连接失败: HTTP " .. tostring(code), data
end

function Auth:is_logged_in()
    return self.cookie:is_valid()
end

function Auth:ensure_logged_in()
    if self.cookie:is_valid() then
        local ok, msg, data = self:test_cookie()
        if ok then
            return true, "Cookie 有效", { method = "cookie", test = data }
        end
        Log.warn("Auth: Cookie 测试失败，尝试重新登录: " .. tostring(msg))
    end
    local account = H.trim(self.account or "")
    local password = H.trim(self.password or "")
    if #account < 6 or #password < 4 then
        return false, "Cookie 无效且未保存账号密码，无法自动重新登录", nil
    end
    Log.info("Auth: 尝试自动重新登录 account=" .. account)
    return self:login(account, password, self.base_host)
end

function Auth:clear()
    self.account = ""
    self.password = ""
    self.uin = ""
    self.cookie:clear()
    self:save_to_settings()
end

function Auth:get_cookie()
    return self.cookie
end

function Auth:get_cookie_header()
    return self.cookie:to_header_string()
end

return Auth
