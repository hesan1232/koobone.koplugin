local ltn12 = require("ltn12")
local H = require("koobone.helper")
local Log = require("koobone.logger")
local _state = require("koobone.state")

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")
local ok_socket_perf, socket_perf = pcall(require, "socket")
local ok_ssl, ssl = pcall(require, "ssl")
local ok_tcp, tcp = pcall(require, "socket.tcp")

local M = {}

local DESKTOP_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

function M.now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.clock() * 1000
end

function M.clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function M.format_size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 then
        return string.format("%dB", math.floor(bytes))
    elseif bytes < 1024 * 1024 then
        return string.format("%.1fKB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1fMB", bytes / (1024 * 1024))
    else
        return string.format("%.1fGB", bytes / (1024 * 1024 * 1024))
    end
end

-- ============================================================
-- IPC: 子进程→父进程进度传递（基于文件）
-- ============================================================

function M.ipc_write_progress(file_path, data)
    if not file_path then return end
    pcall(function()
        local json_str = H.json_encode(data)
        if not json_str then return end
        local tmp = file_path .. ".tmp"
        local f = io.open(tmp, "w")
        if not f then return end
        f:write(json_str)
        f:close()
        os.rename(tmp, file_path)
    end)
end

function M.ipc_read_progress(file_path)
    if not file_path then return nil end
    local f = io.open(file_path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    return H.json_decode(content)
end

function M.ipc_write_cancel(cancel_file)
    if not cancel_file then return end
    pcall(function()
        local f = io.open(cancel_file, "w")
        if f then f:write("1"); f:close() end
    end)
end

function M.ipc_check_cancel(cancel_file)
    if not cancel_file then return false end
    local f = io.open(cancel_file, "r")
    if f then f:close(); return true end
    return false
end

function M.ipc_cleanup(progress_file, cancel_file)
    pcall(os.remove, progress_file)
    pcall(os.remove, cancel_file)
end

-- ============================================================
-- HTTP 传输选择
-- ============================================================

local function pick_transport(url)
    local is_https = url:find("^https://") == 1
    if is_https then
        if not ok_https then
            return nil, nil, "ssl.https is not available"
        end
        return https, true
    else
        if not ok_http then
            return nil, nil, "socket.http is not available"
        end
        return http, false
    end
end

local function build_headers(url, cookie)
    -- 重要：不同服务端防盗链策略不同：
    -- 1. dl.php (dl3.koobone.com/dl.php): 需要 Origin + Referer + Cookie (用户 curl 能成功就是靠这个)
    -- 2. 封面 CDN (img.koobone.com): 只需要 Cookie，带 Referer 会 403
    -- 3. 其他情况：默认带 Referer/Origin 保守处理
    local url_str = tostring(url or "")
    local url_lower = url_str:lower()
    local is_dl_server = url_lower:find("dl%.php") ~= nil or url_lower:find("/dl/") ~= nil or url_lower:find("dl%d*%.koobone%.com") ~= nil

    -- [DEBUG] 记录下载 URL 和匹配结果，帮助排查 403 问题
    Log.debug("[KooboneDownload] build_headers url=" .. url_str:sub(1, 120) .. " is_dl_server=" .. tostring(is_dl_server) .. " cookie_len=" .. tostring(cookie and #cookie or 0))

    local headers = {
        ["User-Agent"] = DESKTOP_UA,
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        ["Accept-Language"] = "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6",
        ["Accept-Encoding"] = "identity",
        ["Cache-Control"] = "max-age=0",
        ["Connection"] = "keep-alive",
        ["Upgrade-Insecure-Requests"] = "1",
    }

    if is_dl_server then
        -- dl.php 下载服务器：对齐用户 curl 成功的 headers
        -- Referer 必须是 https://koobone.com/ （带末尾斜杠）
        -- Origin 必须是 https://koobone.com （不带斜杠）
        headers["Referer"] = "https://koobone.com/"
        headers["Origin"] = "https://koobone.com"
        headers["Sec-Fetch-Dest"] = "empty"
        headers["Sec-Fetch-Mode"] = "cors"
        headers["Sec-Fetch-Site"] = "same-site"
        headers["x-kb-from"] = "KOOBONE/5.0.0 WEB(7) FETCH /"
        -- dl.php 的 Accept 用 */* （对齐 curl）
        headers["Accept"] = "*/*"
        Log.debug("[KooboneDownload] build_headers 添加 Origin+Referer 头 (dl.php 策略)")
    else
        -- 封面 CDN 等其他域名：不带 Referer/Origin，靠 Cookie 通过防盗链
        -- 对齐 client.get_binary 成功策略
        Log.debug("[KooboneDownload] build_headers 不添加 Referer/Origin (非 dl.php 策略)")
    end

    if cookie and cookie ~= "" then
        headers["Cookie"] = cookie
    end
    return headers
end

local function apply_ssl_opts(request_options, is_https, verify_ssl)
    if not is_https then return end
    request_options.mode = "client"
    request_options.protocol = "tlsv1_2"
    request_options.verify = verify_ssl and "peer" or "none"
    request_options.options = "all"
end

-- ============================================================
-- Keep-Alive: 创建可复用的 socket 连接
-- ============================================================

-- 创建一个持久的连接工厂，用于在多个请求间复用 TCP 连接
-- 这避免了每次请求都进行 TCP 握手 + TLS 协商的固定开销
-- 注意: 依赖 socket.tcp 和 ssl 模块，如果不可用则返回 nil
local function create_socket_factory(url, is_https, verify_ssl)
    if not ok_tcp or not tcp then
        Log.debug("[KooboneDownload] socket.tcp 不可用，跳过 Keep-Alive")
        return nil
    end
    if is_https and (not ok_ssl or not ssl) then
        Log.debug("[KooboneDownload] ssl 模块不可用，跳过 Keep-Alive")
        return nil
    end

    local scheme, host_port = url:match("^(https?)://([^/]+)")
    if not host_port then return nil end
    local host, port_str = host_port:match("^([^:]+):?(%d*)$")
    local port = tonumber(port_str) or (is_https and 443 or 80)

    local raw_sock = nil
    local wrapped_sock = nil

    local function connect()
        raw_sock = assert(tcp())
        raw_sock:settimeout(30)
        local ok, err = raw_sock:connect(host, port)
        if not ok then
            return nil, "TCP连接失败: " .. tostring(err)
        end
        if is_https then
            local ssl_ok, ssl_err = pcall(function()
                wrapped_sock = ssl.wrap(raw_sock, {
                    mode = "client",
                    protocol = "tlsv1_2",
                    verify = verify_ssl and "peer" or "none",
                    options = "all",
                })
                assert(wrapped_sock:dohandshake())
            end)
            if not ssl_ok then
                raw_sock:close()
                raw_sock = nil
                return nil, "SSL握手失败: " .. tostring(ssl_err)
            end
        else
            wrapped_sock = raw_sock
        end
        return wrapped_sock
    end

    local function get()
        if wrapped_sock then
            return wrapped_sock
        end
        return connect()
    end

    local function close()
        if wrapped_sock then
            pcall(function() wrapped_sock:close() end)
            wrapped_sock = nil
        end
        if raw_sock then
            pcall(function() raw_sock:close() end)
            raw_sock = nil
        end
    end

    return { get = get, close = close, host = host, port = port, is_https = is_https }
end

-- ============================================================
-- 从 GET 响应头提取 Content-Length（替代独立 HEAD 请求）
-- ============================================================

local function extract_content_length(headers)
    if not headers then return nil end
    for k, v in pairs(headers) do
        if tostring(k):lower() == "content-length" then
            local size = tonumber(v)
            if size and size > 0 then
                return size
            end
        end
    end
    return nil
end

-- ============================================================
-- 核心下载函数
-- ============================================================

function M.do_http_download(url, save_tmp_path, expected_size, verify_ssl, cookie)
    local transport, is_https, err = pick_transport(url)
    if not transport then
        return nil, err
    end

    local default_headers = build_headers(url, cookie)
    local out_file = io.open(save_tmp_path, "wb")
    if not out_file then
        return nil, "无法打开临时文件写入: " .. save_tmp_path
    end

    local downloaded = 0
    local last_progress_bytes = 0
    local last_progress_percent = -1
    local progress_chunk = 256 * 1024
    local expected = tonumber(expected_size) or 0
    local last_ui_update = 0

    local sink_writer = function(chunk, sink_err)
        if chunk == nil then
            return nil, sink_err
        end
        if chunk ~= "" then
            out_file:write(chunk)
            downloaded = downloaded + #chunk
            local now = M.now_ms()
            local should_update = false
            if downloaded - last_progress_bytes >= progress_chunk then
                should_update = true
            end
            if expected > 0 then
                local pct = math.floor((downloaded / expected) * 100)
                if pct - last_progress_percent >= 2 then
                    should_update = true
                    last_progress_percent = pct
                end
            end
            if should_update and (now - last_ui_update) >= 100 then
                last_ui_update = now
                last_progress_bytes = downloaded
                _state.updateDownloadProgress(downloaded, expected, string.format("下载中 %s/%s",
                    M.format_size(downloaded), M.format_size(expected)))
            end
        end
        return chunk
    end

    local custom_sink = setmetatable({}, {
        __call = function(_, chunk, sink_err)
            return sink_writer(chunk, sink_err)
        end
    })

    local request_options = {
        url = url,
        sink = custom_sink,
        timeout = 180,
        headers = default_headers,
    }
    apply_ssl_opts(request_options, is_https, verify_ssl)

    local t0 = M.now_ms()
    local ok_trans, result1, result2, result3 = pcall(transport.request, request_options)
    out_file:close()
    local elapsed = M.now_ms() - t0

    if not ok_trans then
        return nil, "HTTP连接异常: " .. tostring(result1)
    end

    local code = result2
    if type(code) ~= "number" or code < 200 or code >= 300 then
        return nil, "HTTP " .. tostring(code) .. " (elapsed=" .. math.floor(elapsed) .. "ms)"
    end

    return downloaded, nil
end

function M.do_http_download_with_progress(url, save_tmp_path, expected_size, verify_ssl, cookie, progress_callback, cancel_check)
    local transport, is_https, err = pick_transport(url)
    if not transport then
        return nil, err
    end

    local default_headers = build_headers(url, cookie)
    local expected = tonumber(expected_size) or 0

    -- 断点续传: 检查本地已有部分文件
    local exist_size = 0
    local resume_supported = false
    local file_mode = "wb"
    local existing_attr = lfs.attributes(save_tmp_path, "size")
    if existing_attr and existing_attr > 0 then
        exist_size = existing_attr
        if expected > 0 and exist_size >= expected then
            Log.info("[KooboneDownload] 断点检测: 本地文件已完整 exist=" .. exist_size .. " expected=" .. expected)
            if progress_callback then
                progress_callback(exist_size, expected, "done", "断点检测: 文件已完整")
            end
            _state.updateDownloadProgress(exist_size, expected, "断点检测: 文件已完整")
            return exist_size, nil
        end
        default_headers["Range"] = "bytes=" .. tostring(exist_size) .. "-"
        resume_supported = true
        file_mode = "a+b"
        Log.info("[KooboneDownload] 断点续传: 从 " .. exist_size .. " 字节继续下载 (expected=" .. expected .. ")")
        local resume_msg = "断点续传中..."
        if progress_callback then
            progress_callback(exist_size, expected, "resume", resume_msg)
        end
        _state.updateDownloadProgress(exist_size, expected, resume_msg)
    end

    local out_file = io.open(save_tmp_path, file_mode)
    if not out_file then
        return nil, "无法打开临时文件写入: " .. save_tmp_path
    end

    local downloaded = exist_size
    local last_progress_bytes = exist_size
    local last_progress_percent = expected > 0 and math.floor((exist_size / expected) * 100) or -1
    -- 优化: 增大进度块到 1MB，减少 IO 系统调用和 Lua 回调
    local progress_chunk = 1024 * 1024
    local last_ui_update = 0
    local cancelled = false
    local remote_content_length = nil

    local sink_writer = function(chunk, sink_err)
        if chunk == nil then
            return nil, sink_err
        end
        if cancel_check and cancel_check() then
            cancelled = true
            out_file:close()
            return nil, "cancelled"
        end
        if chunk ~= "" then
            out_file:write(chunk)
            downloaded = downloaded + #chunk
            local now = M.now_ms()
            local should_update = false
            if downloaded - last_progress_bytes >= progress_chunk then
                should_update = true
            end
            -- 从响应头自动检测 Content-Length（如果之前不知道 expected）
            if expected <= 0 and remote_content_length and remote_content_length > 0 then
                expected = remote_content_length
                Log.info("[KooboneDownload] 从响应头检测到 Content-Length: " .. expected)
                should_update = true
            end
            if expected > 0 then
                local pct = math.floor((downloaded / expected) * 100)
                if pct - last_progress_percent >= 2 then
                    should_update = true
                    last_progress_percent = pct
                end
            end
            if should_update and (now - last_ui_update) >= 200 then
                last_ui_update = now
                last_progress_bytes = downloaded
                local dl_msg = "下载中..."
                if progress_callback then
                    progress_callback(downloaded, expected, "downloading", dl_msg)
                end
                _state.updateDownloadProgress(downloaded, expected, dl_msg)
            end
        end
        return chunk
    end

    local custom_sink = setmetatable({}, {
        __call = function(_, chunk, sink_err)
            return sink_writer(chunk, sink_err)
        end
    })

    -- 使用 response_headers 捕获表来读取 Content-Length
    local response_headers = {}

    local request_options = {
        url = url,
        sink = custom_sink,
        timeout = 300,
        headers = default_headers,
    }
    apply_ssl_opts(request_options, is_https, verify_ssl)

    local gc_was_running = collectgarbage("isrunning")
    if gc_was_running then
        collectgarbage("stop")
    end

    local t0 = M.now_ms()
    local ok_trans, result1, result2, result3 = pcall(transport.request, request_options)
    out_file:close()
    local elapsed = M.now_ms() - t0

    -- 优化: 从 GET 响应头提取 Content-Length（替代独立的 HEAD 请求）
    if ok_trans and result3 and type(result3) == "table" then
        local cl = extract_content_length(result3)
        if cl then
            remote_content_length = cl
            Log.info("[KooboneDownload] 从 GET 响应头获取 Content-Length: " .. cl)
        end
    end

    if gc_was_running then
        collectgarbage("restart")
        collectgarbage("collect")
    end

    if cancelled then
        Log.info("[KooboneDownload] 下载已取消，保留断点文件: " .. save_tmp_path .. " size=" .. downloaded)
        return nil, "下载已取消"
    end

    if not ok_trans then
        Log.warn("[KooboneDownload] HTTP异常，保留断点文件: " .. save_tmp_path .. " err=" .. tostring(result1))
        return nil, "HTTP连接异常: " .. tostring(result1)
    end

    local code = result2
    if resume_supported and code == 206 then
        Log.info("[KooboneDownload] 断点续传成功 206, downloaded=" .. downloaded .. " (elapsed=" .. math.floor(elapsed) .. "ms)")
        return downloaded, nil
    elseif resume_supported and code == 416 then
        Log.info("[KooboneDownload] 服务器返回 416，本地文件已完整 exist=" .. exist_size)
        return exist_size, nil
    elseif resume_supported and code == 200 then
        Log.warn("[KooboneDownload] 服务器不支持 Range (返回 200)，断点文件已损坏，需删除重下")
        pcall(os.remove, save_tmp_path)
        return nil, "服务器不支持断点续传，请重新下载"
    end

    if type(code) ~= "number" or code < 200 or code >= 300 then
        Log.warn("[KooboneDownload] HTTP " .. tostring(code) .. " 保留断点文件 (elapsed=" .. math.floor(elapsed) .. "ms)")
        return nil, "HTTP " .. tostring(code) .. " (elapsed=" .. math.floor(elapsed) .. "ms)"
    end

    return downloaded, nil
end

function M.get_remote_file_size(url, cookie)
    local transport, is_https, err = pick_transport(url)
    if not transport then
        return nil
    end

    -- 区分 dl.php 和其他域名，build_headers 一致的策略
    local url_str = tostring(url or "")
    local url_lower = url_str:lower()
    local is_dl_server = url_lower:find("dl%.php") ~= nil or url_lower:find("/dl/") ~= nil or url_lower:find("dl%d*%.koobone%.com") ~= nil

    Log.debug("[KooboneDownload] get_remote_file_size url=" .. url_str:sub(1, 120) .. " is_dl_server=" .. tostring(is_dl_server))

    local head_headers = {
        ["User-Agent"] = DESKTOP_UA,
        ["Accept"] = "*/*",
        ["Accept-Language"] = "zh-CN,zh;q=0.9",
        ["Accept-Encoding"] = "identity",
        ["Cache-Control"] = "max-age=0",
        ["Connection"] = "keep-alive",
    }
    if is_dl_server then
        -- dl.php HEAD 请求也带 Origin+Referer，和 GET 一致
        head_headers["Referer"] = "https://koobone.com/"
        head_headers["Origin"] = "https://koobone.com"
        head_headers["Sec-Fetch-Dest"] = "empty"
        head_headers["Sec-Fetch-Mode"] = "cors"
        head_headers["Sec-Fetch-Site"] = "same-site"
        head_headers["x-kb-from"] = "KOOBONE/5.0.0 WEB(7) FETCH /"
    end
    if cookie and cookie ~= "" then
        head_headers["Cookie"] = cookie
    end

    local request_options = {
        method = "HEAD",
        url = url,
        sink = ltn12.sink.null(),
        headers = head_headers,
        timeout = 30,
    }
    apply_ssl_opts(request_options, is_https, true)

    local ok, result1, result2, result3 = pcall(transport.request, request_options)
    if not ok then
        Log.warn("[KooboneDownload] HEAD request failed: " .. tostring(result1))
        return nil
    end

    local code = result2
    if type(code) ~= "number" or code < 200 or code >= 300 then
        Log.warn("[KooboneDownload] HEAD request returned HTTP " .. tostring(code))
        return nil
    end

    local resp_headers = result3 or {}
    local content_length = nil
    for k, v in pairs(resp_headers or {}) do
        if tostring(k):lower() == "content-length" then
            content_length = v
            break
        end
    end
    if content_length then
        local size = tonumber(content_length)
        if size and size > 0 then
            Log.info("[KooboneDownload] HEAD got Content-Length: " .. size)
            return size
        end
    end

    return nil
end

return M