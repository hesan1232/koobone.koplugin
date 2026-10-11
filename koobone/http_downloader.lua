local H = require("koobone.helper")
local Log = require("koobone.logger")
local _state = require("koobone.state")

-- lfs 必须显式 require：KOReader 不提供全局 lfs（全仓库其余模块都是
-- `local lfs = require("libs/libkoreader-lfs")`）。此前裸用 `lfs.attributes`，
-- 在无全局 lfs 的环境会抛 "attempt to index a nil value (global 'lfs')"，
-- 使断点续传的"已有字节数"检测直接失败。
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

-- 注：`ssl` / `socket.tcp` 曾在此 require，供已删除的 keep-alive 连接工厂
-- （create_socket_factory）使用；下载主路径走 pick_transport，不需要它们。
local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")
local ok_socket_perf, socket_perf = pcall(require, "socket")

local M = {}

local DESKTOP_UA = H.DESKTOP_UA

function M.now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.clock() * 1000
end

-- 关闭文件句柄（容错版）。
-- 取消路径会在 sink 里先 close 一次，之后外层还会再 close；而 Lua 5.1/LuaJIT 对
-- 已关闭句柄调用 f:close() 会抛 "attempt to use a closed file"，把它抛出
-- 函数外部会掩盖真正的取消原因。这里统一走 pcall。
local function close_quietly(f)
    if not f then return end
    pcall(function() f:close() end)
end

-- 下载 sink 的速率检测参数。
-- ⚠️ 它检测的不是「完全停住」—— 那种情况 sink 根本不会被调用，由 request_options.timeout
-- 兜底。它检测的是「还在滴数据、但慢到不可用」：没有这一步，一条 200 B/s 的连接会把
-- 180s 的 timeout 全部耗完才算失败（墨水屏上表现为进度条卡着不动很久）。
local STALL_MS = 15000      -- 统计窗口
local MIN_RATE = 1024       -- bytes/s，低于此速率视为停滞

-- ============================================================
-- IPC: 子进程→父进程进度传递（基于文件）
-- ============================================================

-- 进度写入失败只告警一次：本函数在下载过程中每个进度 tick 都会被调用，
-- 若磁盘满 / 句柄失效，逐 tick 告警会把日志刷爆。
local _ipc_progress_warned = false

function M.ipc_write_progress(file_path, data)
    if not file_path then return end
    pcall(function()
        local json_str = H.json_encode(data)
        if not json_str then return end
        local tmp = file_path .. ".tmp"
        local f = io.open(tmp, "w")
        if not f then return end
        -- ⚠️ 返回值必须检查：写失败时下面那句 os.rename 仍可能成功，父进程会读到一个
        -- 空/截断的进度 JSON（表现为进度条不动），而没有任何错误线索。
        local write_ok, write_err = f:write(json_str)
        local close_ok, close_err = f:close()
        if not write_ok or close_ok == nil then
            if not _ipc_progress_warned then
                _ipc_progress_warned = true
                Log.warn("[Koobone] 进度写入失败（后续不再重复告警）: "
                    .. tostring(write_err or close_err))
            end
            pcall(os.remove, tmp)
            return
        end
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

-- 父进程发送取消信号
-- @return boolean 是否确认写入成功。此前无返回值，调用方即使写失败也当作已发送
--         ——「用户点了取消，子进程照跑」就是这么来的。
function M.ipc_write_cancel(cancel_file)
    if not cancel_file then return false end
    local pcall_ok, written = pcall(function()
        local f, open_err = io.open(cancel_file, "w")
        if not f then
            Log.warn("[Koobone] 取消信号无法创建: " .. tostring(open_err))
            return false
        end
        -- ⚠️ 返回值必须检查：这里写不进去 = 取消信号丢失。
        local write_ok, write_err = f:write("1")
        local close_ok, close_err = f:close()
        if not write_ok or close_ok == nil then
            Log.warn("[Koobone] 取消信号写入失败: " .. tostring(write_err or close_err))
            return false
        end
        return true
    end)
    if not pcall_ok then
        Log.warn("[Koobone] 取消信号写入异常: " .. tostring(written))
        return false
    end
    return written == true
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


-- ============================================================
-- 核心下载函数
-- ============================================================


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
    -- lfs.attributes(path, "size") 直接返回字节数（number），不是 attribute 表。
    -- ok_lfs 兜底：lfs 不可用时 exist_size 保持 0 → 退化为整文件重下，不会报错。
    local existing_attr = ok_lfs and lfs and lfs.attributes(save_tmp_path, "size") or nil
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
    local sink_err_msg = nil
    local last_rate_ms = M.now_ms()
    local last_rate_bytes = exist_size

    -- 记住第一个真实失败原因（写失败 / 停滞），供请求返回后精确上报。
    -- 注意不用于「取消」：取消有自己的出口（见函数末尾的 cancelled 分支）。
    local function fail_sink(msg)
        if not sink_err_msg then
            sink_err_msg = msg
            Log.error("[KooboneDownload] " .. msg .. " path=" .. tostring(save_tmp_path))
        end
        return nil, sink_err_msg
    end

    local sink_writer = function(chunk, sink_err)
        if chunk == nil then
            return nil, sink_err
        end
        if cancel_check and cancel_check() then
            cancelled = true
            close_quietly(out_file)
            return nil, "cancelled"
        end
        if sink_err_msg then
            return nil, sink_err_msg
        end
        if chunk ~= "" then
            -- ⚠️ write 的返回值必须检查（同 do_http_download）：磁盘写满 / 配额耗尽时
            -- write 返回 nil, err，不检查的话落盘一个截断的 EPUB 却报「下载成功」。
            local write_ok, write_err = out_file:write(chunk)
            if not write_ok then
                return fail_sink("写入文件失败: " .. tostring(write_err))
            end
            downloaded = downloaded + #chunk
            local now = M.now_ms()
            -- 速率检测（见文件顶部 STALL_MS / MIN_RATE 说明）
            local dt = now - last_rate_ms
            if dt >= STALL_MS then
                local rate = (downloaded - last_rate_bytes) * 1000 / dt
                if rate < MIN_RATE then
                    return fail_sink(string.format("下载停滞（%.0f B/s < %d B/s，已持续 %.0fs）",
                        rate, MIN_RATE, dt / 1000))
                end
                last_rate_ms = now
                last_rate_bytes = downloaded
            end
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
    local ok_trans, result1, result2 = pcall(transport.request, request_options)
    close_quietly(out_file)
    local elapsed = M.now_ms() - t0

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

    -- sink 侧的真实失败原因（写失败 / 停滞）优先于 HTTP 状态码上报：
    -- sink 返回 nil 时 transport 只会给一个含糊的返回值，落到下面会被当成 "HTTP nil"。
    if sink_err_msg then
        Log.warn("[KooboneDownload] " .. sink_err_msg
            .. " 保留断点文件: " .. save_tmp_path .. " size=" .. downloaded)
        return nil, sink_err_msg
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


return M