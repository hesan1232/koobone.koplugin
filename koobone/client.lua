local ltn12 = require("ltn12")
local H = require("koobone.helper")
local Log = require("koobone.logger")
local Koobone = require("koobone.koobone")

local ok_info, Info = pcall(require, "koobone.info")
local CLIENT_VERSION = ok_info and Info and Info.version or "1.4.0"

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")

local ok_socket_perf, socket_perf = pcall(require, "socket")
local function now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.clock() * 1000
end

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT = 15
local DESKTOP_UA = H.DESKTOP_UA
local SHELF_CACHE_TTL = 300  -- 5分钟（与 fanqie 一致，避免重复发起网络请求）

local Client = {}
Client.__index = Client

-- L1 短缓存：vol_list（全局不带 sid）+ 按系列的 vol_list（带 sid）
-- 两级缓存，避免每次进目录都发 HTTP
local VOL_LIST_CACHE_GLOBAL = {
    ts = 0,
    sort = nil,
    data = nil,
}
-- key = series_id, value = { ts, data }
local VOL_LIST_CACHE_BY_SERIES = {}


local function transport_request(transport, request, timeout)
    timeout = timeout or DEFAULT_TIMEOUT
    local previous_timeout = transport.TIMEOUT
    transport.TIMEOUT = timeout
    local t0 = now_ms()
    local ok, result1, result2, result3, result4 = pcall(transport.request, request)
    local elapsed = now_ms() - t0
    transport.TIMEOUT = previous_timeout

    local method = (request and request.method) or "GET"
    local url = (request and request.url) or "?"
    local body_len = 0
    if type(result1) == "string" or type(result1) == "table" then
        body_len = #result1
    end
    Log.debug("[Koobone][perf] transport_request:",
        "method=" .. method,
        "elapsed=" .. string.format("%.0f", elapsed) .. "ms",
        "code=" .. tostring(result2),
        "result_type=" .. type(result1),
        "url=" .. url)

    if not ok then
        error("HTTP连接失败: transport_request抛异常: " .. tostring(result1))
    end
    if result1 == nil and type(result2) == "string" then
        error("HTTP连接失败: transport_request连接失败: " .. result2)
    end
    return result1, result2, result3, result4
end

-- ============================================================
-- 网络错误分级重试
--
-- 移植自 reading.koplugin/reading/webdav.lua 的 RETRY_CONFIG / is_retryable_code /
-- get_retry_delay 三件套。
--
-- 此前 koobone 的 **API 层（本文件）完全没有重试**：一次瞬时连接失败/瞬时 5xx 就会
-- 把异常直接抛给调用方，而 bookshelf:refresh 的整条链是「一次失败即中止」——
-- 于是弱网下打开书架＝「书架为空/拉取失败」，缓存的旧数据白留着没用上。
-- （唯一的重试逻辑在 **EPUB 下载路径**：download.lua 的「策略链 + 同策略 3 次重试」；
--   那一层走 http_downloader 直连 transport，不经过本文件，两者互不影响、不会叠加。）
--
-- ⚠️ 调用点全部位于 Async.run 子进程内（bookshelf:refresh / progress:query_vol_info /
--    shelf_view 的单张封面下载），因此下面的 socket.sleep 不会阻塞 UI 线程。
-- ============================================================
local RETRY_CONFIG = {
    max_retries   = 2,   -- 最大重试次数（总请求次数 = 1 + max_retries = 3）
    initial_delay = 1,   -- 首次重试前的等待秒数
    max_delay     = 4,   -- 退避延迟上限
}

-- 判断响应码是否为可重试的瞬时错误。
--   · code == nil        → 请求抛异常 / 连接被重置，瞬时错误，重试；
--   · 5xx / 408 / 429    → 服务端瞬时故障或限流，重试；
--   · 其余 4xx（401/403/404…）与业务错误 → 确定性错误，重试无意义，**立即停**。
local function is_retryable_code(code)
    if code == nil then return true end
    if type(code) ~= "number" then return false end
    return (code >= 500 and code <= 599) or code == 408 or code == 429
end

-- 指数退避：第 attempt 次失败后的等待秒数（1s, 2s, 4s...，受 max_delay 封顶）
local function get_retry_delay(attempt)
    local delay = RETRY_CONFIG.initial_delay * (2 ^ (attempt - 1))
    if delay > RETRY_CONFIG.max_delay then
        delay = RETRY_CONFIG.max_delay
    end
    return delay
end

-- 带重试的请求执行器。
-- attempt_fn: 闭包，**每次调用都必须重新构建 sink 等状态**并执行 transport_request
--             （沿用上一次的 sink 会把两次响应体拼在一起 → JSON 解析必然失败）；
--             抛异常视为可重试的瞬时错误。
-- description: 日志用描述（如 "GET https://…/series_list.php"）。
-- 返回: 与 attempt_fn 相同的多返回值；重试耗尽后若最后一次是异常，则原样重新抛出，
--       保持调用方此前依赖的「连接失败会 error」行为不变。
local function request_with_retry(description, attempt_fn)
    local attempt = 0
    while true do
        attempt = attempt + 1
        local ok, r1, r2, r3, r4 = pcall(attempt_fn)

        -- 异常一律视为瞬时错误；正常返回时按响应码分级
        local retryable = (not ok) or is_retryable_code(r2)

        if not retryable then
            return r1, r2, r3, r4
        end

        if attempt > RETRY_CONFIG.max_retries then
            if not ok then
                -- 保持原行为：连接失败原样抛出（level 0 → 不带本文件位置前缀）
                error(r1, 0)
            end
            Log.warn(string.format("[Koobone] 请求[%s] 重试 %d 次后仍失败: code=%s",
                description, RETRY_CONFIG.max_retries, tostring(r2)))
            return r1, r2, r3, r4
        end

        local delay = get_retry_delay(attempt)
        Log.warn(string.format("[Koobone] 请求[%s] 第 %d 次失败(%s)，%.1fs 后重试",
            description, attempt, ok and tostring(r2) or tostring(r1), delay))
        if ok_socket_perf and socket_perf and socket_perf.sleep then
            socket_perf.sleep(delay)
        end
    end
end

function Client:new(settings, auth)
    local obj = setmetatable({
        settings = settings,
        auth = auth,
    }, self)
    return obj
end

-- L1: 清理 API 层短缓存（force_refresh / 主动清缓存时调用）
function Client:clearVolListCache()
    VOL_LIST_CACHE_GLOBAL.ts = 0
    VOL_LIST_CACHE_GLOBAL.sort = nil
    VOL_LIST_CACHE_GLOBAL.data = nil
    VOL_LIST_CACHE_BY_SERIES = {}
    Log.debug("[Koobone] clearVolListCache: 全局+按系列 L1 API短缓存已清空")
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:_build_base_url()
    local raw_host = self.settings:get_base_host() or Koobone.DEFAULT_HOST
    local base = Koobone.normalize_base(raw_host)

    local scheme_match, host_match = base:match("^(https?)://(.+)$")
    local scheme, host
    if scheme_match and host_match then
        scheme = scheme_match
        host = host_match
    else
        host = base
        scheme = Koobone.is_local_host(base) and "http" or "https"
    end

    -- 移除可能的端口号用于本地判断
    local host_only = host:gsub(":%d+$", "")
    local is_local = host_only == "127.0.0.1" or host_only == "localhost"
    if is_local then
        scheme = "http"
    end

    return scheme .. "://" .. host, scheme, host
end

function Client:request(opts)
    opts = opts or {}
    local method = opts.method or "GET"
    local path = opts.path or "/"
    local query_str = opts.query_str or ""
    local body = opts.body
    local headers = opts.headers or {}
    local timeout = opts.timeout or DEFAULT_TIMEOUT

    -- 修复: 如果调用方传入了完整 url（如 auth.lua 的登录请求），直接使用，不重新构造
    local full_url, scheme, base_host
    if opts.url and opts.url ~= "" then
        full_url = opts.url
        -- 从 url 解析 scheme 和 host 用于 X-KB-FROM/Referer/Origin
        local scheme_match, host_match = opts.url:match("^(https?)://([^/]+)")
        if scheme_match and host_match then
            scheme = scheme_match
            base_host = host_match
        else
            scheme = "https"
            base_host = Koobone.DEFAULT_HOST
        end
    else
        local base_url
        base_url, scheme, base_host = self:_build_base_url()
        full_url = base_url .. path
        if query_str ~= "" then
            if query_str:sub(1, 1) == "?" then
                full_url = full_url .. query_str
            else
                full_url = full_url .. "?" .. query_str
            end
        end
    end

    headers["User-Agent"] = headers["User-Agent"] or DESKTOP_UA
    headers["Accept"] = headers["Accept"] or "application/json, text/plain, */*"
    headers["Accept-Encoding"] = "identity"
    headers["Connection"] = "keep-alive"
    headers["X-Requested-With"] = "XMLHttpRequest"

    -- 认证：X-KB-INFO 直接使用个人页面 API Key
    local api_key = self.auth and self.auth.get_api_key and self.auth:get_api_key() or ""
    if api_key ~= "" then
        headers["X-KB-INFO"] = api_key
    end

    headers["X-KB-FROM"] = headers["X-KB-FROM"] or Koobone.build_kb_from(CLIENT_VERSION)
    headers["Referer"] = headers["Referer"] or (scheme .. "://" .. base_host .. "/")
    headers["Origin"] = headers["Origin"] or (scheme .. "://" .. base_host)

    if body then
        headers["Content-Length"] = tostring(#body)
    end

    local transport = full_url:match("^https:") and https or http
    if full_url:match("^https:") and not ok_https then
        error("HTTP连接失败: ssl.https is not available")
    elseif not transport and not ok_http then
        error("HTTP连接失败: socket.http is not available")
    end

    -- 每次尝试都重建 response/sink：失败尝试的响应体（如 5xx 错误页）已被写进 sink，
    -- 沿用同一个表会把两次响应拼在一起 → 后续 JSON 解析必然失败。
    local response = {}
    local function do_request()
        response = {}
        return transport_request(transport, {
            url = full_url,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = ltn12.sink.table(response),
        }, timeout)
    end
    -- 分级重试：瞬时错误（连接失败 / 5xx / 408 / 429）自动退避重试，4xx 立即返回
    local _, code, resp_headers, status = request_with_retry(
        method .. " " .. full_url, do_request)

    local body_text = table.concat(response)
    if not code or (type(code) == "number" and code >= 400) then
        Log.warn("[Koobone] HTTP请求异常:",
            "method=" .. method,
            "path=" .. path,
            "code=" .. tostring(code),
            "status=" .. tostring(status or "nil"),
            "body_len=" .. tostring(#body_text))
    end

    if opts.return_header then
        return body_text, tonumber(code), resp_headers or {}, status
    end
    return body_text, tonumber(code), resp_headers or {}, status
end

-- 拉取二进制数据（图片/封面等小文件）
-- 参考 fanqie client:get_binary：返回原始 body 字符串（可能是二进制），不处理 JSON
-- 用于封面下载（图片 URL 可能是 CDN 域名 img.koobone.com，不是主站 koobone.com）
function Client:get_binary(url, opts)
    opts = opts or {}
    local timeout = opts.timeout or 30

    local scheme_match = url:match("^(https?)://")
    local transport = (scheme_match == "https") and https or http
    if scheme_match == "https" and not ok_https then
        error("get_binary: ssl.https is not available (url=" .. tostring(url) .. ")")
    end
    if not transport then
        error("get_binary: no HTTP transport available (url=" .. tostring(url) .. ")")
    end

    local scheme_host = url:match("^(https?://[^/]+)") or ""

    -- CDN 图片请求：api_key 直传鉴权，无需 cookie
    -- 如果调用方显式传了 opts.referer / opts.headers 则以调用方为准。
    local headers = {
        ["User-Agent"] = DESKTOP_UA,
        ["Accept"] = opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        ["Accept-Language"] = opts.accept_language or "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6",
        ["Accept-Encoding"] = "identity",
        ["Cache-Control"] = "max-age=0",
        ["Upgrade-Insecure-Requests"] = "1",
        ["Connection"] = "keep-alive",
    }
    if opts.referer then
        headers["Referer"] = opts.referer
    end
    if opts.headers then
        for k, v in pairs(opts.headers) do
            headers[k] = v
        end
    end

    local response = {}
    -- 每次尝试都重建 sink（失败尝试的响应体已写入 response，沿用会把两次响应拼接）
    local function do_request()
        response = {}
        local request_options = {
            url = url,
            method = "GET",
            headers = headers,
            sink = ltn12.sink.table(response),
        }
        -- SSL bypass（和 EPUB/HttpDL 一致：Kindle 旧 CA 无法验证 img.koobone.com 证书）
        if scheme_match == "https" then
            request_options.mode = "client"
            request_options.protocol = "tlsv1_2"
            request_options.verify = "none"
            request_options.options = "all"
        end
        return transport_request(transport, request_options, timeout)
    end

    -- 分级重试（同 Client:request）：封面是 CDN 图片，限流/瞬时 5xx 很常见
    local _, code = request_with_retry("get_binary " .. url, do_request)
    local data = table.concat(response)
    if type(code) ~= "number" or code < 200 or code >= 300 then
        error(string.format("get_binary: HTTP %s url=%s", tostring(code), tostring(url)))
    end
    return data, tonumber(code)
end

function Client:is_auth_error(code, body_text)
    if code == 401 or code == 403 then
        return true
    end
    body_text = tostring(body_text or "")
    if body_text == "" then
        return false
    end
    local looks_like_json = body_text:match("^%s*{") ~= nil or body_text:match("^%s*%[") ~= nil
    if looks_like_json and #body_text <= 65536 then
        local ok, data = pcall(function()
            return self:json_decode(body_text)
        end)
        if ok and type(data) == "table" then
            local err_message = tostring(data.message or data.msg or "")
            if err_message:find("登录", 1, true) then
                return true
            end
        end
    end
    return false
end


local function normalize_vol_item(item)
    if not item or type(item) ~= "table" then
        return nil
    end
    local fmd = tostring(item.file_md5 or item.fmd or "")
    local title = tostring(item.vol_name or item.name or item.title or "")
    -- 修复: 如果 vol_name 为空，回退用 file_md5 前8位作为标题，避免"未命名"
    if title == "" and fmd ~= "" then
        title = fmd:sub(1, 8)
    end
    local series = tostring(item.vol_series or item.series or item.vol_seriesid or "")
    -- 修复: 如果 API 不返回 vol_seriesid，用 vol_series（系列名称）作为分组 key
    local series_id = tostring(item.vol_seriesid or item.series_id or "")
    if series_id == "" and series ~= "" then
        series_id = series
    end
    -- 调试日志: 打印原始字段名（仅第一次）
    if not _NORMALIZE_DEBUGGED then
        _NORMALIZE_DEBUGGED = true
        local keys = {}
        for k, _ in pairs(item) do
            table.insert(keys, tostring(k))
        end
        Log.debug("[Koobone] vol_list 原始字段: " .. table.concat(keys, ", "))
        Log.debug("[Koobone] vol_list 样例: vol_name=" .. tostring(item.vol_name)
            .. " vol_series=" .. tostring(item.vol_series)
            .. " vol_seriesid=" .. tostring(item.vol_seriesid)
            .. " vol_author=" .. tostring(item.vol_author)
            .. " file_md5=" .. tostring(item.file_md5))
    end
    return {
        fmd = fmd,
        title = title,
        author = tostring(item.vol_author or item.author or ""),
        series = series,
        series_id = series_id,
        cover_url = tostring(item.cover_url or item.cover or item.thumb or ""),
        file_url = tostring(item.file_url or ""),
        file_size = tonumber(item.file_size) or 0,
        file_md5 = fmd,
        total_pages = tonumber(item.count_page or item.pages) or 0,
        last_readpage = tonumber(item.last_readpage or item.last_read_page) or 0,
        update_time = tonumber(item.time_update or item.uptime) or 0,
        add_time = tonumber(item.time_add) or 0,
        read_count = tonumber(item.count_read) or 0,
        vol_snumber = tonumber(item.vol_snumber or item.snumber or item.sort or 0) or 0,
        status = tostring(item.status or item.state or ""),
        _raw = item,
    }
end

local function extract_vol_array(resp_data)
    if not resp_data or type(resp_data) ~= "table" then
        return {}
    end
    if type(resp_data.data) == "table" and #resp_data.data > 0 then
        return resp_data.data
    end
    if type(resp_data.list) == "table" and #resp_data.list > 0 then
        return resp_data.list
    end
    if type(resp_data.vols) == "table" and #resp_data.vols > 0 then
        return resp_data.vols
    end
    if type(resp_data.items) == "table" and #resp_data.items > 0 then
        return resp_data.items
    end
    if #resp_data > 0 then
        return resp_data
    end
    return {}
end

-- params: sort, limit, page, sid(系列id), sna(系列名)
-- fanqie 对齐模式：
--   书架 → client:get_series_list() → series_list.php（全局系列）
--   目录 → client:get_vol_list{ sid=series_id, sna=series_title } → vol_list.php?sid=&sna=（该系列卷）
function Client:get_vol_list(params)
    params = params or {}
    local sort = params.sort or "uptime"
    local limit = params.limit or 200
    local page = params.page or 1
    local sid = params.sid and tostring(params.sid) or ""
    local sna = params.sna and tostring(params.sna) or ""
    local force = params.force and true or false
    -- 按系列查询：sid 或 sna 有值就算（seriesid 为空的系列只靠 sna 查）
    local by_series = sid ~= "" or sna ~= ""
    -- 缓存 key：sid 非空用 sid，否则用 sna
    local series_cache_key = sid ~= "" and sid or sna

    local now = os.time()

    -- force=true：强制绕过 L1 短缓存（用户主动刷新）
    if not force then
        -- 按系列查询（目录）：独立缓存
        if by_series then
            local cache = VOL_LIST_CACHE_BY_SERIES[series_cache_key]
            if cache
                and (now - cache.ts) < SHELF_CACHE_TTL
                and cache.sort == sort then
                Log.debug("[Koobone] get_vol_list(series) 命中缓存 key=", series_cache_key, " age=", now - cache.ts, "s")
                return cache.data
            end
        else
            -- 全局查询：原 VOL_LIST_CACHE_GLOBAL
            if VOL_LIST_CACHE_GLOBAL.data
                and (now - VOL_LIST_CACHE_GLOBAL.ts) < SHELF_CACHE_TTL
                and VOL_LIST_CACHE_GLOBAL.sort == sort then
                Log.debug("[Koobone] get_vol_list(global) 命中缓存 age=", now - VOL_LIST_CACHE_GLOBAL.ts, "s")
                return VOL_LIST_CACHE_GLOBAL.data
            end
        end
    end

    Log.info("[Koobone] get_vol_list: sort=" .. sort .. ", limit=" .. limit
        .. (by_series and (", sid=" .. sid .. ", sna=" .. sna) or ", global"))

    local all_vols = {}
    local current_page = page
    local totalpage = 1

    while current_page <= totalpage do
        local query = "by=" .. H.url_encode(sort)
            .. "&limit=" .. H.url_encode(tostring(limit))
            .. "&page=" .. H.url_encode(tostring(current_page))
        if by_series then
            -- 与 curl 示例对齐：sid=KMOE:xxx，sna=URL编码的系列名
            if sna ~= "" then
                query = query .. "&sna=" .. H.url_encode(sna)
            end
            query = query .. "&sid=" .. H.url_encode(sid)
        end

        Log.debug("[Koobone] get_vol_list 拉取第", current_page, "页 query=", query)

        local text, code = self:request({
            method = "GET",
            path = "/vol_list.php",
            query_str = query,
        })

        if not code or code < 200 or code >= 300 then
            error("获取卷列表失败: HTTP " .. tostring(code))
        end

        local ok, resp_data = pcall(function()
            return self:json_decode(text)
        end)

        if not ok or not resp_data then
            Log.warn("[Koobone] get_vol_list 第", current_page, "页JSON解析失败")
            break
        end

        local page_vols = extract_vol_array(resp_data)
        Log.debug("[Koobone] get_vol_list 第", current_page, "页返回", #page_vols, "条")

        for _, item in ipairs(page_vols) do
            local norm = normalize_vol_item(item)
            if norm then
                table.insert(all_vols, norm)
            end
        end

        if type(resp_data) == "table" then
            totalpage = tonumber(resp_data.totalpage) or 1
        end

        current_page = current_page + 1
    end

    Log.info("[Koobone] get_vol_list 完成, 共", #all_vols, "卷", by_series and (" key=" .. series_cache_key) or " global")

    -- 写入缓存
    if by_series then
        VOL_LIST_CACHE_BY_SERIES[series_cache_key] = {
            ts = now,
            sort = sort,
            data = all_vols,
        }
    else
        VOL_LIST_CACHE_GLOBAL.ts = now
        VOL_LIST_CACHE_GLOBAL.sort = sort
        VOL_LIST_CACHE_GLOBAL.data = all_vols
    end

    return all_vols
end

-- L1 短缓存：series_list（书架主数据源，5分钟 TTL）
local SERIES_LIST_CACHE = {
    ts = 0,
    sort = nil,
    data = nil,
}

function Client:clearSeriesListCache()
    SERIES_LIST_CACHE.ts = 0
    SERIES_LIST_CACHE.sort = nil
    SERIES_LIST_CACHE.data = nil
    Log.debug("[Koobone] clearSeriesListCache: L1 series_list API短缓存已清空")
end

function Client:get_series_list(params)
    params = params or {}
    local sort = params.sort or "uptime"
    local limit = params.limit or 50
    local page = params.page or 1
    local force = params.force and true or false

    local now = os.time()

    -- force=true：强制绕过 L1 短缓存（用于用户主动刷新书架）
    if not force and SERIES_LIST_CACHE.data
        and (now - SERIES_LIST_CACHE.ts) < SHELF_CACHE_TTL
        and SERIES_LIST_CACHE.sort == sort then
        Log.debug("[Koobone] get_series_list 命中缓存 age=", now - SERIES_LIST_CACHE.ts, "s")
        return SERIES_LIST_CACHE.data
    end

    Log.info("[Koobone] get_series_list: sort=" .. sort)

    local query = "by=" .. H.url_encode(sort)
        .. "&limit=" .. H.url_encode(tostring(limit))
        .. "&page=" .. H.url_encode(tostring(page))

    local text, code = self:request({
        method = "GET",
        path = "/series_list.php",
        query_str = query,
    })

    local series_list = {}

    if code and code >= 200 and code < 300 then
        local ok, resp_data = pcall(function()
            return self:json_decode(text)
        end)
        if ok and resp_data then
            local raw_list = {}
            if type(resp_data.data) == "table" and #resp_data.data > 0 then
                raw_list = resp_data.data
            elseif type(resp_data.list) == "table" and #resp_data.list > 0 then
                raw_list = resp_data.list
            elseif type(resp_data.series) == "table" and #resp_data.series > 0 then
                raw_list = resp_data.series
            elseif type(resp_data.items) == "table" and #resp_data.items > 0 then
                raw_list = resp_data.items
            elseif #resp_data > 0 then
                raw_list = resp_data
            end

            if #raw_list > 0 then
                for _, s in ipairs(raw_list) do
                    if type(s) == "table" then
                        -- 调试日志：打印 series 原始字段名（仅第一次）
                        if not _SERIES_DEBUGGED then
                            _SERIES_DEBUGGED = true
                            local keys = {}
                            for k, _ in pairs(s) do
                                table.insert(keys, tostring(k))
                            end
                            Log.debug("[Koobone] series_list 原始字段: " .. table.concat(keys, ", "))
                            Log.debug("[Koobone] series_list 样例: seriesid=" .. tostring(s.seriesid)
                                .. " series=" .. tostring(s.series)
                                .. " cover_url=" .. tostring(s.cover_url)
                                .. " seq=" .. tostring(s.seq))
                        end
                        -- seriesid 可能为空字符串（如"地獄樂" seriesid=""），
                        -- 空时用系列名作为 id（书架唯一标识 + 封面文件名 + is_vol_downloaded key）
                        -- 同时保留原始 seriesid（api_sid）供 vol_list.php 查询用
                        local api_sid = tostring(s.seriesid or s.series_id or s.sid or "")
                        local sid = api_sid
                        if sid == "" then
                            sid = tostring(s.series or s.name or s.title or s.series_name or "")
                        end
                        table.insert(series_list, {
                            id = sid,
                            api_sid = api_sid,
                            title = tostring(s.series or s.name or s.title or s.series_name or ""),
                            author = tostring(s.author or s.writer or ""),
                            cover_url = tostring(s.cover_url or s.cover or s.thumb or ""),
                            status = tostring(s.status or s.state or ""),
                            progress = tonumber(s.progress or s.read_progress) or 0,
                            comic_count = tonumber(s.count_vol or s.vol_count or s.vols or s.count) or 0,
                            latest_name = tostring(s.latest or s.last_vol or s.latest_name or ""),
                            update_time = tonumber(s.time_update or s.uptime or s.update_time) or 0,
                            _raw = s,
                        })
                    end
                end
            end
        end
    end

    Log.info("[Koobone] get_series_list 完成, 共", #series_list, "系列")

    -- 写入 L1 缓存（即使为空也写入，避免空值连续打 API）
    SERIES_LIST_CACHE.ts = now
    SERIES_LIST_CACHE.sort = sort
    SERIES_LIST_CACHE.data = series_list

    return series_list
end

function Client:report_read_page(fmd, page, total_or_nil)
    local base_url, scheme, base_host = self:_build_base_url()
    local ts = tostring(os.time())
    local query_str = "act=readpage"
        .. "&fmd=" .. H.url_encode(fmd)
        .. "&par=" .. H.url_encode(tostring(page or 0))
        .. "&r=" .. ts

    if total_or_nil then
        query_str = query_str .. "&par2=" .. H.url_encode(tostring(total_or_nil))
    end

    Log.debug("[Koobone] report_read_page: fmd=" .. fmd .. ", page=" .. tostring(page))

    -- ⚠️ pcall 的第一个返回值是「成功标志」，其后才是被包函数的返回值。
    -- 本函数在 return_header=true 时，Client:request 返回 (text, code, headers, status)，
    -- 必须逐个接住。旧写法 `local ok, err = pcall(...)` 只接住前两个：`err` 其实是响应体
    -- text，code/headers/status 全为 nil → 下面 `not code` 恒真 → 每次都被迫降级到
    -- act=uptime（而 uptime 不携带页码 par2）→ 带页码的 act=readpage 从未真正走通。
    local ok, text, code = pcall(function()
        return self:request({
            method = "GET",
            path = "/vol_act.php",
            query_str = query_str,
            headers = {
                ["X-KB-FROM"] = Koobone.build_kb_from(CLIENT_VERSION),
                ["Referer"] = scheme .. "://" .. base_host .. "/web.htm",
            },
            return_header = true,
        })
    end)

    local resp_obj = nil
    if ok and text and text ~= "" then
        pcall(function()
            resp_obj = self:json_decode(text)
        end)
    end

    if not ok or not code or (type(code) == "number" and code >= 400) then
        -- pcall 失败时，text 位置收到的是错误消息（request 抛异常）
        Log.warn("[Koobone] report_read_page act=readpage 失败 (ok=" .. tostring(ok)
        .. ", code=" .. tostring(code or "nil")
        .. (not ok and (", err=" .. tostring(text)) or "")
        .. "), fallback 到 act=uptime...")
        local fb_ok, fb_msg, fb_resp = self:report_uptime(fmd)
        return fb_ok, fb_msg, fb_resp, true
    end

    local success = true
    local message = "success"
    if resp_obj and type(resp_obj) == "table" then
        if resp_obj.code and tonumber(resp_obj.code) ~= 0 then
            success = false
        end
        message = tostring(resp_obj.message or resp_obj.msg or message)
    end

    return success, message, resp_obj, false
end

--- 上传阅读进度到云端。
-- shelf_view 的"手动上传云端进度"此前调用了一个并不存在的方法 `client:upload_progress`，
-- 被 pcall/Async 吞掉后永远显示"上传失败"。这里补上，统一复用 report_read_page 链路
-- （含 act=uptime 兜底），并把返回值规整成 (ok, msg)。
-- @return boolean ok
-- @return string  成功/失败信息
function Client:upload_progress(fmd, page, total_or_nil)
    if not fmd or fmd == "" then
        return false, "fmd 为空"
    end

    local called_ok, success, message = pcall(function()
        return self:report_read_page(fmd, tonumber(page) or 0, tonumber(total_or_nil) or nil)
    end)

    if not called_ok then
        return false, tostring(success or "upload exception")
    end
    return success == true, tostring(message or "")
end

function Client:report_uptime(fmd)
    local ts = tostring(os.time())
    local query_str = "act=uptime"
        .. "&fmd=" .. H.url_encode(fmd)
        .. "&r=" .. ts

    Log.debug("[Koobone] report_uptime: fmd=" .. fmd)

    local text, code = self:request({
        method = "GET",
        path = "/vol_act.php",
        query_str = query_str,
    })

    local resp_obj = nil
    if text and text ~= "" then
        pcall(function()
            resp_obj = self:json_decode(text)
        end)
    end

    if not code or code < 200 or code >= 300 then
        return false, "HTTP " .. tostring(code), resp_obj
    end

    local success = true
    local message = "success"
    if resp_obj and type(resp_obj) == "table" then
        if resp_obj.code and tonumber(resp_obj.code) ~= 0 then
            success = false
        end
        message = tostring(resp_obj.message or resp_obj.msg or message)
    end

    return success, message, resp_obj
end

function Client:query_vol_info(fmd)
    Log.debug("[Koobone] query_vol_info: fmd=" .. tostring(fmd))

    if not fmd or fmd == "" then
        return nil, "fmd 为空"
    end

    local vols = self:get_vol_list({ sort = "uptime", limit = 200 })

    local target = tostring(fmd)
    for _, vol in ipairs(vols) do
        if tostring(vol.file_md5) == target or tostring(vol.fmd) == target then
            Log.info("[Koobone] query_vol_info 匹配成功:",
                " fmd=" .. target,
                " title=" .. (vol.title or "?"),
                " pages=" .. tostring(vol.total_pages),
                " last_page=" .. tostring(vol.last_readpage))
            return vol
        end
    end

    Log.warn("[Koobone] query_vol_info 未在书架中匹配到 fmd=" .. target .. " (书架共" .. #vols .. "卷)")
    return nil, "未在书架中匹配到 fmd=" .. tostring(fmd)
end

return Client
