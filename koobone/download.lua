local lfs = require("libs/libkoreader-lfs")
local ltn12 = require("ltn12")
local H = require("koobone.helper")
local Log = require("koobone.logger")
local Async = require("koobone.async")
local _state = require("koobone.state")
local ok_DLProgress, DownloadProgress = pcall(require, "koobone.download_progress")
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")
local ok_zip, zip = pcall(require, "zip")

local ok_socket_perf, socket_perf = pcall(require, "socket")
local function now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.clock() * 1000
end

local DESKTOP_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

local Download = {}
Download.__index = Download

function Download:new(settings, client, bookshelf)
    local obj = {
        settings = settings,
        client = client,
        bookshelf = bookshelf,
        EPUB_CACHE_DIR = H.get_epub_dir(),
        MAX_CACHE_BYTES = (settings:get_cache_max_mb() or 1024) * 1024 * 1024,
        MAX_AGE_SECONDS = 48 * 3600,
        _active_downloads = {},
        _download_queue = {},
        _queue_processing = false,
        _queue_listeners = {},
    }
    H.make_dir(obj.EPUB_CACHE_DIR)
    return setmetatable(obj, self)
end

function Download:_cache_key(fmd, file_md5)
    local md5 = file_md5 and tostring(file_md5) or ""
    if md5 ~= "" then
        return H.trim(md5)
    end
    return H.trim(tostring(fmd or "unknown"))
end

function Download:_epub_path(fmd, file_md5)
    local key = self:_cache_key(fmd, file_md5)
    return H.join_path(self.EPUB_CACHE_DIR, key .. ".epub")
end

function Download:_extract_dir(fmd, file_md5)
    local key = self:_cache_key(fmd, file_md5)
    return H.join_path(self.EPUB_CACHE_DIR, key)
end

function Download:_pages_idx_path(fmd, file_md5)
    return H.join_path(self:_extract_dir(fmd, file_md5), "_pages.json")
end

function Download:_file_size(path)
    if H.file_size then
        return H.file_size(path)
    end
    local size = lfs.attributes(path, "size")
    return size or 0
end

function Download:_file_mtime(path)
    local mtime = lfs.attributes(path, "modification")
    return mtime or 0
end

function Download:_safe_rmtree(dir)
    H.delete_dir(dir)
end

function Download:_dir_size(dir)
    if not H.dir_exists(dir) then return 0 end
    local total = 0
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full = H.join_path(dir, entry)
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                total = total + self:_dir_size(full)
            else
                total = total + self:_file_size(full)
            end
        end
    end
    return total
end

function Download:_lru_cleanup()
    if not H.dir_exists(self.EPUB_CACHE_DIR) then
        return
    end
    local now_ts = os.time()
    local entries = {}
    local total_bytes = 0
    local ok, err = pcall(function()
        for name in lfs.dir(self.EPUB_CACHE_DIR) do
            if name ~= "." and name ~= ".." then
                local p = H.join_path(self.EPUB_CACHE_DIR, name)
                local attr_ok, attr = pcall(function() return lfs.attributes(p) end)
                if attr_ok and attr then
                    local atime = attr.access or attr.modification or now_ts
                    if now_ts - atime > self.MAX_AGE_SECONDS then
                        local mode = attr.mode
                        if mode == "directory" then
                            Log.info("[KooboneCache] 清理过期目录:", name)
                            self:_safe_rmtree(p)
                        else
                            Log.info("[KooboneCache] 清理过期文件:", name)
                            os.remove(p)
                        end
                    else
                        local size = 0
                        if attr.mode == "directory" then
                            size = self:_dir_size(p)
                        else
                            size = attr.size or 0
                        end
                        total_bytes = total_bytes + size
                        table.insert(entries, { atime = atime, size = size, path = p, name = name })
                    end
                end
            end
        end

        local limit_bytes = math.floor(self.MAX_CACHE_BYTES * 0.8)
        if total_bytes > self.MAX_CACHE_BYTES then
            table.sort(entries, function(a, b)
                return a.atime < b.atime
            end)
            for _, entry in ipairs(entries) do
                if total_bytes <= limit_bytes then
                    break
                end
                local attr_ok2, attr2 = pcall(function() return lfs.attributes(entry.path) end)
                if attr_ok2 and attr2 then
                    local mode = attr2.mode
                    if mode == "directory" then
                        Log.info("[KooboneCache] 清理最旧目录(总大小超限):", entry.name)
                        self:_safe_rmtree(entry.path)
                    else
                        Log.info("[KooboneCache] 清理最旧文件(总大小超限):", entry.name)
                        os.remove(entry.path)
                    end
                end
                total_bytes = total_bytes - entry.size
            end
        end
    end)
    if not ok then
        Log.warn("[KooboneCache] LRU cleanup exception:", tostring(err))
    end
end

local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function format_size(bytes)
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

-- ===== 子进程→父进程进度 IPC（基于文件）=====
-- Async.run 通过 fork 在子进程中执行下载，子进程无法直接更新父进程的 UI。
-- 通过临时文件传递进度：子进程写入 JSON，父进程轮询读取并更新对话框。
-- 通过 cancel 文件传递取消信号：父进程创建文件，子进程检查文件是否存在。

local function ipc_write_progress(file_path, data)
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

local function ipc_read_progress(file_path)
    if not file_path then return nil end
    local f = io.open(file_path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return nil end
    return H.json_decode(content)
end

local function ipc_write_cancel(cancel_file)
    if not cancel_file then return end
    pcall(function()
        local f = io.open(cancel_file, "w")
        if f then f:write("1"); f:close() end
    end)
end

local function ipc_check_cancel(cancel_file)
    if not cancel_file then return false end
    local f = io.open(cancel_file, "r")
    if f then f:close(); return true end
    return false
end

local function ipc_cleanup(progress_file, cancel_file)
    pcall(os.remove, progress_file)
    pcall(os.remove, cancel_file)
end

function Download:_do_http_download(url, save_tmp_path, expected_size, verify_ssl, fmd)
    local ltn12_mod = ltn12
    local is_https = url:find("^https://") == 1
    local transport
    if is_https then
        if not ok_https then
            return nil, "ssl.https is not available"
        end
        transport = https
    else
        if not ok_http then
            return nil, "socket.http is not available"
        end
        transport = http
    end

    local scheme_host = url:match("^(https?://[^/]+)") or ""
    local default_headers = {
        ["User-Agent"] = DESKTOP_UA,
        ["Accept"] = "application/epub+zip, application/zip, application/octet-stream, */*",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
        ["Referer"] = scheme_host .. "/",
        ["Origin"] = scheme_host,
    }
    local cookie = self.settings:get_cookie()
    if cookie and cookie ~= "" then
        default_headers["Cookie"] = cookie
    end

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

    local sink_writer = function(chunk, err)
        if chunk == nil then
            return nil, err
        end
        if chunk ~= "" then
            out_file:write(chunk)
            downloaded = downloaded + #chunk
            local now = now_ms()
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
                    format_size(downloaded), format_size(expected)))
            end
        end
        return chunk
    end

    local custom_sink = setmetatable({}, {
        __call = function(_, chunk, err)
            return sink_writer(chunk, err)
        end
    })

    local request_options = {
        url = url,
        sink = custom_sink,
        timeout = 180,
        headers = default_headers,
    }

    if is_https and transport == https then
        if not verify_ssl then
            request_options.mode = "client"
            request_options.protocol = "tlsv1_2"
            request_options.verify = "none"
            request_options.options = "all"
        else
            request_options.mode = "client"
            request_options.protocol = "tlsv1_2"
            request_options.verify = "peer"
            request_options.options = "all"
        end
    end

    local t0 = now_ms()
    local ok_trans, result1, result2, result3 = pcall(transport.request, request_options)
    out_file:close()
    local elapsed = now_ms() - t0

    if not ok_trans then
        return nil, "HTTP连接异常: " .. tostring(result1)
    end

    local code = result2
    if type(code) ~= "number" or code < 200 or code >= 300 then
        return nil, "HTTP " .. tostring(code) .. " (elapsed=" .. math.floor(elapsed) .. "ms)"
    end

    return downloaded, nil
end

--- 带进度回调的 HTTP 下载
function Download:_do_http_download_with_progress(url, save_tmp_path, expected_size, verify_ssl, fmd, progress_callback, cancel_check)
    local is_https = url:find("^https://") == 1
    local transport
    if is_https then
        if not ok_https then
            return nil, "ssl.https is not available"
        end
        transport = https
    else
        if not ok_http then
            return nil, "socket.http is not available"
        end
        transport = http
    end

    local scheme_host = url:match("^(https?://[^/]+)") or ""
    local default_headers = {
        ["User-Agent"] = DESKTOP_UA,
        ["Accept"] = "application/epub+zip, application/zip, application/octet-stream, */*",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
        ["Referer"] = scheme_host .. "/",
        ["Origin"] = scheme_host,
    }
    local cookie = self.settings:get_cookie()
    if cookie and cookie ~= "" then
        default_headers["Cookie"] = cookie
    end

    local expected = tonumber(expected_size) or 0

    -- ===== 断点续传: 检查本地已有部分文件 =====
    local exist_size = 0
    local resume_supported = false
    local file_mode = "wb"
    local existing_attr = lfs.attributes(save_tmp_path, "size")
    if existing_attr and existing_attr > 0 then
        exist_size = existing_attr
        -- 如果已有大小 >= 预期大小，说明文件已完整，直接返回
        if expected > 0 and exist_size >= expected then
            Log.info("[KooboneDownload] 断点检测: 本地文件已完整 exist=" .. exist_size .. " expected=" .. expected)
            if progress_callback then
                progress_callback(exist_size, expected, "done", "断点检测: 文件已完整")
            end
            _state.updateDownloadProgress(exist_size, expected, "断点检测: 文件已完整")
            return exist_size, nil
        end
        -- 加入 Range 头尝试续传
        default_headers["Range"] = "bytes=" .. tostring(exist_size) .. "-"
        resume_supported = true
        file_mode = "a+b"
        Log.info("[KooboneDownload] 断点续传: 从 " .. exist_size .. " 字节继续下载 (expected=" .. expected .. ")")
        local resume_msg = "断点续传中..."
        if progress_callback then
            progress_callback(exist_size, expected, "resume", resume_msg)
        end
        -- 同步更新全局状态（后台下载时书架界面也能看到断点进度）
        _state.updateDownloadProgress(exist_size, expected, resume_msg)
    end

    local out_file = io.open(save_tmp_path, file_mode)
    if not out_file then
        return nil, "无法打开临时文件写入: " .. save_tmp_path
    end

    -- downloaded 从已有大小开始累计（用于进度显示）
    local downloaded = exist_size
    local last_progress_bytes = exist_size
    local last_progress_percent = expected > 0 and math.floor((exist_size / expected) * 100) or -1
    local progress_chunk = 256 * 1024

    local last_ui_update = 0
    local cancelled = false

    local sink_writer = function(chunk, err)
        if chunk == nil then
            return nil, err
        end

        -- 检查取消
        if cancel_check and cancel_check() then
            cancelled = true
            out_file:close()
            return nil, "cancelled"
        end

        if chunk ~= "" then
            out_file:write(chunk)
            downloaded = downloaded + #chunk
            local now = now_ms()
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
        __call = function(_, chunk, err)
            return sink_writer(chunk, err)
        end
    })

    local request_options = {
        url = url,
        sink = custom_sink,
        timeout = 300,  -- 优化: 5分钟超时，适配 100MB 大文件 + Kindle 慢网络
        headers = default_headers,
    }

    if is_https and transport == https then
        if not verify_ssl then
            request_options.mode = "client"
            request_options.protocol = "tlsv1_2"
            request_options.verify = "none"
            request_options.options = "all"
        else
            request_options.mode = "client"
            request_options.protocol = "tlsv1_2"
            request_options.verify = "peer"
            request_options.options = "all"
        end
    end

    -- 优化: 下载前暂停 GC，减少大文件流式写入时的 GC pause
    local gc_was_running = collectgarbage("isrunning")
    if gc_was_running then
        collectgarbage("stop")
    end

    local t0 = now_ms()
    local ok_trans, result1, result2, result3 = pcall(transport.request, request_options)
    out_file:close()
    local elapsed = now_ms() - t0

    -- 优化: 下载后恢复 GC 并手动收尾
    if gc_was_running then
        collectgarbage("restart")
        collectgarbage("collect")
    end

    if cancelled then
        -- 取消时保留 tmp 文件以便下次续传
        Log.info("[KooboneDownload] 下载已取消，保留断点文件: " .. save_tmp_path .. " size=" .. downloaded)
        return nil, "下载已取消"
    end

    if not ok_trans then
        -- 异常时也保留 tmp 文件以便续传
        Log.warn("[KooboneDownload] HTTP异常，保留断点文件: " .. save_tmp_path .. " err=" .. tostring(result1))
        return nil, "HTTP连接异常: " .. tostring(result1)
    end

    local code = result2
    -- 处理断点续传响应码
    if resume_supported and code == 206 then
        -- 服务器支持 Range，追加写入成功
        Log.info("[KooboneDownload] 断点续传成功 206, downloaded=" .. downloaded .. " (elapsed=" .. math.floor(elapsed) .. "ms)")
        return downloaded, nil
    elseif resume_supported and code == 416 then
        -- 416 Range Not Satisfiable: 本地文件已完整（或超出服务器文件大小）
        Log.info("[KooboneDownload] 服务器返回 416，本地文件已完整 exist=" .. exist_size)
        return exist_size, nil
    elseif resume_supported and code == 200 then
        -- 服务器不支持 Range，返回了完整内容。但我们的文件已用 "a+b" 打开追加写，
        -- 这会导致重复数据！需要重新覆盖写。
        -- 由于 out_file 已关闭，且 sink 已写入追加数据，文件已损坏，需删除重下。
        Log.warn("[KooboneDownload] 服务器不支持 Range (返回 200)，断点文件已损坏，需删除重下")
        pcall(os.remove, save_tmp_path)
        return nil, "服务器不支持断点续传，请重新下载"
    end

    if type(code) ~= "number" or code < 200 or code >= 300 then
        -- 失败时保留 tmp 文件以便续传
        Log.warn("[KooboneDownload] HTTP " .. tostring(code) .. " 保留断点文件 (elapsed=" .. math.floor(elapsed) .. "ms)")
        return nil, "HTTP " .. tostring(code) .. " (elapsed=" .. math.floor(elapsed) .. "ms)"
    end

    return downloaded, nil
end

function Download:_download_epub_file(vol, file_url, expected_size, file_md5)
    local fmd = tostring(vol.file_md5 or vol.fmd or "unknown")
    H.make_dir(self.EPUB_CACHE_DIR)
    local epub_path = self:_epub_path(fmd, file_md5)
    expected_size = tonumber(expected_size) or 0

    if H.file_exists(epub_path) then
        local cur_size = self:_file_size(epub_path)
        if expected_size and expected_size > 0 then
            local ratio = cur_size / expected_size
            if ratio >= 0.95 and ratio <= 1.05 then
                Log.info("[KooboneDownload] 命中缓存 fmd=" .. fmd .. " size=" .. tostring(cur_size))
                return epub_path, nil
            end
        else
            return epub_path, nil
        end
    end

    local tmp_path = epub_path .. ".downloading"
    -- 优化: 不再无条件删除 tmp 文件，保留用于断点续传

    local is_https = file_url:find("^https://") == 1
    local http_url = nil
    if is_https then
        http_url = "http://" .. file_url:sub(9)
    end

    local strategies = {
        { name = "HTTPS+Verify", url = file_url, verify = true },
    }
    if is_https then
        table.insert(strategies, { name = "HTTPS+NoVerify", url = file_url, verify = false })
        if http_url then
            table.insert(strategies, { name = "HTTP+Fallback", url = http_url, verify = true })
        end
    end

    local last_err = nil
    local strat_names = {}
    for _, s in ipairs(strategies) do table.insert(strat_names, s.name) end
    Log.info("[KooboneDownload] 策略列表(无进度): " .. table.concat(strat_names, ", ") .. " fmd=" .. fmd)
    local prev_strat_url = nil
    for si, strat in ipairs(strategies) do
        Log.info("[KooboneDownload] 使用策略 " .. strat.name .. " (第" .. si .. "/" .. #strategies .. "个) verify=" .. tostring(strat.verify))
        -- 优化: 切换策略(URL变化)时删除 tmp 文件，同一策略重试则保留断点
        if prev_strat_url and prev_strat_url ~= strat.url then
            if H.file_exists(tmp_path) then
                Log.info("[KooboneDownload] 切换策略(无进度)，删除旧断点文件重新下载")
                pcall(os.remove, tmp_path)
            end
        end
        prev_strat_url = strat.url
        for attempt = 1, 3 do
            -- 优化: 同一策略重试时不删除 tmp 文件，利用断点续传
            local exist_bytes = self:_file_size(tmp_path)
            if exist_bytes > 0 then
                _state.updateDownloadProgress(exist_bytes, expected_size, "断点续传尝试" .. attempt .. "/3")
            else
                _state.updateDownloadProgress(0, expected_size, "下载策略:" .. strat.name .. " 尝试" .. attempt .. "/3")
            end
            -- 优化: 复用带断点续传的下载方法（传 nil 回调走无进度模式）
            local ok_call, size, err = pcall(function()
                return self:_do_http_download_with_progress(strat.url, tmp_path, expected_size, strat.verify, fmd, nil, nil)
            end)
            if not ok_call then
                last_err = tostring(size or "unknown error")
                Log.warn("[KooboneDownload] 策略 " .. strat.name .. " 尝试" .. attempt
                    .. "/3 异常 fmd=" .. fmd .. " err=" .. last_err)
            elseif size and not err then
                local rename_ok, rename_err = os.rename(tmp_path, epub_path)
                if not rename_ok then
                    pcall(os.remove, tmp_path)
                    last_err = "临时文件重命名失败: " .. tostring(rename_err)
                    Log.warn("[KooboneDownload] 文件重命名失败: " .. last_err)
                else
                    Log.info("[KooboneDownload] 下载完成 strategy=" .. strat.name
                        .. " fmd=" .. fmd .. " size=" .. tostring(size))
                    _state.updateDownloadProgress(size, expected_size, "下载完成")
                    return epub_path, nil
                end
            else
                last_err = tostring(err or "unknown")
                Log.warn("[KooboneDownload] 策略 " .. strat.name .. " 尝试" .. attempt
                    .. "/3 失败 fmd=" .. fmd .. " err=" .. last_err)
            end
        end
        Log.info("[KooboneDownload] 策略 " .. strat.name .. " 所有尝试已失败，继续下一策略")
    end

    Log.warn("[KooboneDownload] 所有策略均已失败(无进度) fmd=" .. fmd .. " last_err=" .. tostring(last_err))
    if H.file_exists(tmp_path) then
        pcall(os.remove, tmp_path)
    end
    return nil, "下载 EPUB 失败: " .. tostring(last_err)
end

--- 获取远程文件大小（通过 HEAD 请求）
-- @param url 文件 URL
-- @return file_size 文件大小（字节），失败返回 nil
function Download:_get_remote_file_size(url)
    local is_https = url:find("^https://") == 1
    local transport
    if is_https then
        if not ok_https then return nil end
        transport = https
    else
        if not ok_http then return nil end
        transport = http
    end

    local response_headers = {}
    local scheme_host = url:match("^(https?://[^/]+)") or ""
    local head_headers = {
        ["User-Agent"] = DESKTOP_UA,
        ["Accept"] = "*/*",
        ["Connection"] = "keep-alive",
        ["Referer"] = scheme_host .. "/",
    }
    local cookie = self.settings:get_cookie()
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

    if is_https and transport == https then
        request_options.mode = "client"
        request_options.protocol = "tlsv1_2"
        request_options.verify = "peer"
        request_options.options = "all"
    end

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

    local resp_headers = result3 or response_headers
    -- 从响应头中提取 Content-Length（大小写不敏感）
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

--- 带进度回调的 EPUB 下载方法
-- @param vol 卷信息
-- @param file_url 下载链接
-- @param expected_size 预期文件大小
-- @param file_md5 文件 MD5
-- @param progress_callback 进度回调 function(current, total, stage, message)
-- @param cancel_check 取消检查回调 function() -> boolean
-- @return epub_path, err
function Download:_download_epub_file_with_progress(vol, file_url, expected_size, file_md5, progress_callback, cancel_check)
    local fmd = tostring(vol.file_md5 or vol.fmd or "unknown")
    H.make_dir(self.EPUB_CACHE_DIR)
    local epub_path = self:_epub_path(fmd, file_md5)
    expected_size = tonumber(expected_size) or 0

    -- 如果没有文件大小，尝试通过 HEAD 请求获取
    if expected_size == 0 then
        if progress_callback then
            progress_callback(0, 0, "prepare", "正在获取文件大小...")
        end
        expected_size = self:_get_remote_file_size(file_url) or 0
        if expected_size > 0 then
            Log.info("[KooboneDownload] 通过 HEAD 请求获取文件大小: " .. expected_size)
        else
            Log.warn("[KooboneDownload] 无法获取文件大小，进度条可能不准确")
        end
    end

    -- 检查缓存
    if H.file_exists(epub_path) then
        local cur_size = self:_file_size(epub_path)
        if expected_size and expected_size > 0 then
            local ratio = cur_size / expected_size
            if ratio >= 0.95 and ratio <= 1.05 then
                Log.info("[KooboneDownload] 命中缓存 fmd=" .. fmd .. " size=" .. tostring(cur_size))
                if progress_callback then
                    progress_callback(cur_size, expected_size, "done", "命中缓存")
                end
                return epub_path, nil
            end
        else
            if progress_callback then
                progress_callback(cur_size, expected_size, "done", "命中缓存")
            end
            return epub_path, nil
        end
    end

    local tmp_path = epub_path .. ".downloading"
    -- 优化: 不再无条件删除 tmp 文件，保留用于断点续传

    -- 检查取消
    if cancel_check and cancel_check() then
        if progress_callback then
            progress_callback(0, expected_size, "cancelled", "下载已取消")
        end
        return nil, "下载已取消"
    end

    local is_https = file_url:find("^https://") == 1
    local http_url = nil
    if is_https then
        http_url = "http://" .. file_url:sub(9)
    end

    local strategies = {
        { name = "HTTPS+Verify", url = file_url, verify = true },
    }
    if is_https then
        table.insert(strategies, { name = "HTTPS+NoVerify", url = file_url, verify = false })
        if http_url then
            table.insert(strategies, { name = "HTTP+Fallback", url = http_url, verify = true })
        end
    end

    local last_err = nil
    local strat_names = {}
    for _, s in ipairs(strategies) do table.insert(strat_names, s.name) end
    Log.info("[KooboneDownload] 策略列表: " .. table.concat(strat_names, ", ") .. " fmd=" .. fmd)
    local prev_strat_url = nil
    for si, strat in ipairs(strategies) do
        Log.info("[KooboneDownload] 使用策略 " .. strat.name .. " (第" .. si .. "/" .. #strategies .. "个) verify=" .. tostring(strat.verify))
        -- 优化: 切换策略(URL变化)时删除 tmp 文件重新开始，同一策略重试则保留断点
        if prev_strat_url and prev_strat_url ~= strat.url then
            if H.file_exists(tmp_path) then
                Log.info("[KooboneDownload] 切换策略(URL变化)，删除旧断点文件重新下载")
                pcall(os.remove, tmp_path)
            end
        end
        prev_strat_url = strat.url

        -- 检查取消
        if cancel_check and cancel_check() then
            Log.info("[KooboneDownload] 下载被取消，跳过后续策略（保留断点文件）")
            if progress_callback then
                progress_callback(0, expected_size, "cancelled", "下载已取消")
            end
            return nil, "下载已取消"
        end

        for attempt = 1, 3 do
            -- 再次检查取消
            if cancel_check and cancel_check() then
                Log.info("[KooboneDownload] 下载被取消(尝试" .. attempt .. ")（保留断点文件）")
                if progress_callback then
                    progress_callback(0, expected_size, "cancelled", "下载已取消")
                end
                return nil, "下载已取消"
            end

            -- 优化: 同一策略重试时不删除 tmp 文件，利用断点续传
            if progress_callback then
                local exist_bytes = self:_file_size(tmp_path)
                if exist_bytes > 0 then
                    progress_callback(exist_bytes, expected_size, "resume", "断点续传尝试 " .. attempt .. "/3")
                else
                    progress_callback(0, expected_size, "downloading", "下载策略:" .. strat.name .. " 尝试" .. attempt .. "/3")
                end
            end

            -- 带进度的 HTTP 下载（使用 pcall 防止异常中断策略循环）
            local ok_call, size, err = pcall(function()
                return self:_do_http_download_with_progress(strat.url, tmp_path, expected_size, strat.verify, fmd, progress_callback, cancel_check)
            end)

            if not ok_call then
                last_err = tostring(size or "unknown error")
                Log.warn("[KooboneDownload] 策略 " .. strat.name .. " 尝试" .. attempt
                    .. "/3 异常 fmd=" .. fmd .. " err=" .. last_err)
            elseif size and not err then
                local rename_ok, rename_err = os.rename(tmp_path, epub_path)
                if not rename_ok then
                    pcall(os.remove, tmp_path)
                    last_err = "临时文件重命名失败: " .. tostring(rename_err)
                    Log.warn("[KooboneDownload] 文件重命名失败: " .. last_err)
                else
                    Log.info("[KooboneDownload] 下载完成 strategy=" .. strat.name
                        .. " fmd=" .. fmd .. " size=" .. tostring(size))
                    if progress_callback then
                        progress_callback(size, expected_size, "done", "下载完成")
                    end
                    return epub_path, nil
                end
            else
                last_err = tostring(err or "unknown")
                Log.warn("[KooboneDownload] 策略 " .. strat.name .. " 尝试" .. attempt
                    .. "/3 失败 fmd=" .. fmd .. " err=" .. last_err)
            end
        end
        Log.info("[KooboneDownload] 策略 " .. strat.name .. " 所有尝试已失败，继续下一策略")
    end

    Log.warn("[KooboneDownload] 所有策略均已失败 fmd=" .. fmd .. " last_err=" .. tostring(last_err))
    if H.file_exists(tmp_path) then
        pcall(os.remove, tmp_path)
    end
    return nil, "下载 EPUB 失败: " .. tostring(last_err)
end

local function read_file_text(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*all")
    f:close()
    if not data then return nil end
    local ok_txt, txt = pcall(function()
        return data:gsub("\0", "")
    end)
    if ok_txt then return txt end
    return data
end

local function path_normalize(p)
    if not p then return "" end
    p = p:gsub("\\", "/")
    local parts = {}
    for part in p:gmatch("([^/]+)") do
        if part == ".." then
            if #parts > 0 then
                table.remove(parts)
            end
        elseif part ~= "." and part ~= "" then
            table.insert(parts, part)
        end
    end
    local result = table.concat(parts, "/")
    if p:sub(1, 1) == "/" then
        result = "/" .. result
    end
    return result
end

local function join_url(base, rel)
    if not rel or rel == "" then return "" end
    if rel:find("^%a+://") then return rel end
    if rel:sub(1, 1) == "/" then
        local scheme_host = base:match("^(https?://[^/]+)") or ""
        return scheme_host .. rel
    end
    local base_dir = base:match("^(.*)/[^/]*$") or base
    return path_normalize(base_dir .. "/" .. rel)
end

function Download:_extract_zip_library(epub_path, extract_dir)
    if not ok_zip or not zip then
        return false
    end
    local ok, err = pcall(function()
        local zfile, zerr = zip.open(epub_path)
        if not zfile then
            error("zip.open failed: " .. tostring(zerr))
        end
        for entry in zfile:files() do
            local entry_name = entry.filename
            if entry_name and entry_name ~= "" then
                local target = H.join_path(extract_dir, entry_name)
                if entry_name:sub(-1) == "/" then
                    H.make_dir(target)
                else
                    local parent = target:match("^(.*)[/\\]")
                    if parent and parent ~= target then
                        H.make_dir(parent)
                    end
                    local f, err_open = zfile:open(entry_name)
                    if f then
                        local out_f, err_out = io.open(target, "wb")
                        if out_f then
                            while true do
                                local data = f:read(65536)
                                if not data or #data == 0 then break end
                                out_f:write(data)
                            end
                            out_f:close()
                        end
                        f:close()
                    end
                end
            end
        end
        zfile:close()
    end)
    if ok then
        return true
    else
        Log.warn("[KooboneDownload] Lua zip 库解压失败，尝试 shell:", tostring(err))
        return false
    end
end

-- Lua 5.1 兼容的 os.execute 成功判断：
-- Lua 5.1: 返回 number（0=成功，非0=失败），某些实现（如 Windows）可能返回 boolean
-- Lua 5.2+: 返回 (true, "exit", code) 或 (nil, "signal", signo)
local function _os_execute_ok(...)
    local n = select("#", ...)
    if n >= 2 then
        -- Lua 5.2+: 第二个值是原因字符串 "exit" / "signal"
        local _, reason = ...
        return reason == "exit" and select(3, ...) == 0
    end
    -- Lua 5.1: 单返回值（number 0 或 boolean true 都表示成功）
    local r = select(1, ...)
    return r == 0 or r == true
end

function Download:_extract_zip_shell(epub_path, extract_dir)
    local epub_norm = epub_path:gsub("\\", "/")
    local extract_norm = extract_dir:gsub("\\", "/")
    local cmd
    if package.config:sub(1, 1) == "\\" then
        cmd = string.format('unzip -o -q "%s" -d "%s" 2>nul', epub_norm, extract_norm)
    else
        cmd = string.format('unzip -o -q "%s" -d "%s" 2>/dev/null', epub_norm, extract_norm)
    end
    if _os_execute_ok(os.execute(cmd)) then
        return true
    end
    return false
end

function Download:_extract_epub(epub_path, extract_dir)
    if H.dir_exists(extract_dir) then
        self:_safe_rmtree(extract_dir)
    end
    H.make_dir(extract_dir)
    if ok_zip then
        if self:_extract_zip_library(epub_path, extract_dir) then
            return true
        end
    end
    if self:_extract_zip_shell(epub_path, extract_dir) then
        return true
    end
    return false
end

local IMAGE_EXTS = {
    [".jpg"] = true, [".jpeg"] = true, [".png"] = true,
    [".webp"] = true, [".gif"] = true, [".bmp"] = true,
    [".tiff"] = true, [".avif"] = true,
}

local function is_image_name(name)
    if not name then return false end
    local ext = name:match("%.([^%.]+)$")
    if not ext then return false end
    return IMAGE_EXTS["." .. ext:lower()] == true
end

function Download:_parse_epub_pages(epub_path, extract_dir, expected_file_md5, expected_size)
    local epub_size_cur = 0
    local epub_mtime_cur = 0
    if H.file_exists(epub_path) then
        epub_size_cur = self:_file_size(epub_path)
        epub_mtime_cur = self:_file_mtime(epub_path)
    end

    local pages_idx = H.join_path(extract_dir, "_pages.json")

    local function cache_valid()
        if not H.file_exists(pages_idx) then
            return false, nil
        end
        local text = read_file_text(pages_idx)
        if not text then
            return false, nil
        end
        local data = H.json_decode(text)
        if not data or type(data) ~= "table" then
            return false, nil
        end
        local cached_md5 = H.trim(tostring(data.file_md5 or ""))
        local cached_size = tonumber(data.epub_size) or 0
        local cached_mtime = tonumber(data.epub_mtime) or 0
        local pages = data.pages
        if type(pages) ~= "table" or #pages == 0 then
            return false, nil
        end
        local ok = true
        local exp_md5 = H.trim(tostring(expected_file_md5 or ""))
        if exp_md5 ~= "" and cached_md5 ~= "" and cached_md5 ~= exp_md5 then
            ok = false
        end
        if cached_size > 0 and epub_size_cur > 0 and cached_size ~= epub_size_cur then
            ok = false
        end
        if cached_mtime > 0 and epub_mtime_cur > 0 and cached_mtime ~= epub_mtime_cur then
            ok = false
        end
        return ok, pages
    end

    local valid, cached_pages = cache_valid()
    if valid and cached_pages then
        Log.debug("[KooboneDownload] _pages.json 命中 md5="
            .. tostring(expected_file_md5 or "?"):sub(1, 12) .. " pages=" .. #cached_pages)
        return cached_pages, nil
    end

    if H.dir_exists(extract_dir) then
        Log.info("[KooboneDownload] _pages.json 校验不匹配，删除旧解压目录")
        self:_safe_rmtree(extract_dir)
    end
    H.make_dir(extract_dir)

    local extract_ok = self:_extract_epub(epub_path, extract_dir)
    if not extract_ok then
        return nil, "解压 EPUB/ZIP 失败"
    end

    local container_xml = H.join_path(extract_dir, "META-INF", "container.xml")
    if not H.file_exists(container_xml) then
        return nil, "EPUB 缺少 META-INF/container.xml"
    end
    local container_text = read_file_text(container_xml)
    if not container_text then
        return nil, "无法读取 container.xml"
    end

    local opf_rel_path = container_text:match("<rootfile[^>]+full%-path%s*=%s*[\"']([^\"']+)[\"']")
    if not opf_rel_path or opf_rel_path == "" then
        return nil, "container.xml 中找不到 rootfile@full-path"
    end
    opf_rel_path = opf_rel_path:gsub("\\", "/")

    local opf_abs = H.join_path(extract_dir, opf_rel_path)
    if not H.file_exists(opf_abs) then
        return nil, "OPF 文件不存在: " .. opf_rel_path
    end
    local opf_text = read_file_text(opf_abs)
    if not opf_text then
        return nil, "无法读取 OPF 文件"
    end

    local opf_rel_dir = opf_rel_path:match("^(.*)/[^/]*$") or ""
    local opf_abs_dir = opf_abs:match("^(.*)[/\\][^/\\]*$") or extract_dir

    local manifest = {}
    for id, href, mtype in opf_text:gmatch("<item[^>]+id%s*=%s*[\"']([^\"']+)[\"'][^>]*href%s*=%s*[\"']([^\"']+)[\"'][^>]*media%-type%s*=%s*[\"']([^\"']+)[\"']") do
        manifest[id] = { href = href, type = (mtype or ""):lower() }
    end
    for href, id, mtype in opf_text:gmatch("<item[^>]+href%s*=%s*[\"']([^\"']+)[\"'][^>]*id%s*=%s*[\"']([^\"']+)[\"'][^>]*media%-type%s*=%s*[\"']([^\"']+)[\"']") do
        if not manifest[id] then
            manifest[id] = { href = href, type = (mtype or ""):lower() }
        end
    end

    local spine_ids = {}
    for idref in opf_text:gmatch("<itemref[^>]+idref%s*=%s*[\"']([^\"']+)[\"']") do
        if idref ~= "" then
            table.insert(spine_ids, idref)
        end
    end

    local function rel_to_extract(href_rel_to_opf)
        if not href_rel_to_opf then return "" end
        local abs
        if opf_rel_dir == "" then
            abs = href_rel_to_opf
        else
            abs = opf_rel_dir .. "/" .. href_rel_to_opf
        end
        return path_normalize(abs)
    end

    local function resolve_html_imgs(html_rel_to_extract)
        local html_abs = H.join_path(extract_dir, html_rel_to_extract)
        if not H.file_exists(html_abs) then
            return {}
        end
        local text = read_file_text(html_abs)
        if not text then
            return {}
        end
        local html_dir = html_rel_to_extract:match("^(.*)/[^/]*$") or ""
        local result = {}
        for src in text:gmatch("<img[^>]+src%s*=%s*[\"']([^\"']+)[\"']") do
            src = H.trim(src)
            if src ~= "" and not src:find("^data:") and not src:find("^https?://") then
                local rel
                if html_dir == "" then
                    rel = src
                else
                    rel = html_dir .. "/" .. src
                end
                rel = path_normalize(rel)
                local abs_check = H.join_path(extract_dir, rel)
                if is_image_name(rel) and H.file_exists(abs_check) then
                    table.insert(result, rel)
                end
            end
        end
        return result
    end

    local pages = {}
    local seen = {}
    for _, sid in ipairs(spine_ids) do
        local item = manifest[sid]
        if item then
            local href = item.href
            local mtype = item.type
            local rel = rel_to_extract(href)
            local rel_abs = H.join_path(extract_dir, rel)

            if is_image_name(rel) then
                if not seen[rel] and H.file_exists(rel_abs) then
                    table.insert(pages, rel)
                    seen[rel] = true
                end
            elseif mtype:find("image/", 1, true) then
                if not seen[rel] and H.file_exists(rel_abs) then
                    table.insert(pages, rel)
                    seen[rel] = true
                end
            elseif mtype:find("html", 1, true)
                or href:lower():match("%.x?html?$") then
                local imgs = resolve_html_imgs(rel)
                for _, img in ipairs(imgs) do
                    if not seen[img] then
                        table.insert(pages, img)
                        seen[img] = true
                    end
                end
            end
        end
    end

    if #pages < 3 then
        local imgs_manifest = {}
        for _, minfo in pairs(manifest) do
            local rp = rel_to_extract(minfo.href)
            local check_path = H.join_path(extract_dir, rp)
            if is_image_name(rp) and H.file_exists(check_path) then
                table.insert(imgs_manifest, rp)
            end
        end
        if #imgs_manifest > #pages then
            Log.info("[KooboneDownload] spine 解析图片数=" .. #pages
                .. " 太少，改用 manifest 排序 " .. #imgs_manifest .. " 张")
            table.sort(imgs_manifest)
            pages = imgs_manifest
        end
    end

    if #pages == 0 then
        return nil, "未在 EPUB 中解析到任何图片页面"
    end

    local out_obj = {
        file_md5 = H.trim(tostring(expected_file_md5 or "")),
        epub_size = tonumber(epub_size_cur) or 0,
        epub_mtime = tonumber(epub_mtime_cur) or 0,
        pages = pages,
    }
    local json_text = H.json_encode(out_obj)
    if json_text then
        local idx_file = io.open(pages_idx, "w")
        if idx_file then
            idx_file:write(json_text)
            idx_file:close()
        end
    end

    Log.info("[KooboneDownload] 解析 EPUB 完成: " .. #pages .. " 页 md5="
        .. tostring(expected_file_md5 or "(none)"):sub(1, 12))
    return pages, nil
end

function Download:ensure_epub(fmd_or_vol, progress_callback, ipc_opts)
    local vol
    local fmd_str
    if type(fmd_or_vol) == "string" then
        fmd_str = fmd_or_vol
        if self.bookshelf then
            vol = self.bookshelf:get_vol_by_fmd(fmd_str)
        end
    elseif type(fmd_or_vol) == "table" then
        vol = fmd_or_vol
        fmd_str = tostring(vol.file_md5 or vol.fmd or "")
    else
        return nil, nil, nil, "参数错误: 需要 fmd(string) 或 vol(table)"
    end

    ipc_opts = ipc_opts or {}
    local progress_file = ipc_opts.progress_file
    local cancel_file = ipc_opts.cancel_file

    -- 修复1: 重复下载保护 - 同一卷正在下载时返回 in_progress
    local key = self:_cache_key(fmd_str, vol and vol.file_md5 or nil)
    if self._active_downloads[key] then
        Log.info("[KooboneDownload] 卷正在下载中: " .. key)
        if progress_callback then
            progress_callback("prepare", 0, "该卷正在下载中，请稍候...")
        end
        if progress_file then
            ipc_write_progress(progress_file, {
                current = 0, total = 0, stage = "prepare",
                message = "该卷正在下载中，请稍候...",
                vol_name = tostring((vol and (vol.title or vol.vol_name)) or fmd_str),
            })
        end
        -- 等待已有下载完成（使用 socket.sleep 替代 os.execute("sleep")，避免 fork shell）
        local ok_socket_wait, socket_wait = pcall(require, "socket")
        local wait_start = os.clock()
        local timeout = 300 -- 5 分钟超时
        while self._active_downloads[key] and (os.clock() - wait_start) < timeout do
            if cancel_file and ipc_check_cancel(cancel_file) then
                return nil, nil, nil, "下载已取消"
            end
            if ok_socket_wait and socket_wait then
                socket_wait.sleep(0.5)
            else
                -- 退化: 无 socket 模块时用 busy-wait（子进程中可接受）
                local t0 = os.clock()
                while os.clock() - t0 < 0.5 do end
            end
        end
        if self._active_downloads[key] then
            return nil, nil, nil, "下载超时"
        end
        -- 重新检查缓存
        local file_md5 = vol and vol.file_md5 or fmd_str
        local epub_path = self:_epub_path(fmd_str, file_md5)
        local pages_idx = self:_pages_idx_path(fmd_str, file_md5)
        if H.file_exists(epub_path) and H.file_exists(pages_idx) then
            local pages = self:get_pages(fmd_str)
            local edir = self:_extract_dir(fmd_str, file_md5)
            return vol, pages, edir, nil
        end
        return nil, nil, nil, "下载失败"
    end

    -- 检查是否已缓存（避免重复下载）
    local file_md5_check = vol and vol.file_md5 or fmd_str
    local epub_path_check = self:_epub_path(fmd_str, file_md5_check)
    local pages_idx_check = self:_pages_idx_path(fmd_str, file_md5_check)
    if H.file_exists(epub_path_check) and H.file_exists(pages_idx_check) then
        Log.info("[KooboneDownload] 卷已缓存，跳过下载: " .. key)
        if progress_callback then
            progress_callback("done", 100, "已缓存，直接打开")
        end
        local pages = self:get_pages(fmd_str)
        local edir = self:_extract_dir(fmd_str, file_md5_check)
        return vol, pages, edir, nil
    end

    -- 标记为正在下载
    self._active_downloads[key] = { start_time = os.clock() }

    local function cleanup_download()
        self._active_downloads[key] = nil
    end

    -- ===== 创建下载进度对话框 =====
    -- 子进程模式（progress_file 已设置）下不创建对话框，通过文件 IPC 传递进度
    local progress_dialog = nil
    local cancelled = false
    local vol_title_ipc = (vol and (vol.title or vol.vol_name)) or fmd_str
    if not progress_file and ok_DLProgress and DownloadProgress then
        local vol_title = vol_title_ipc
        progress_dialog = DownloadProgress:new{
            title = _("下载中"),
            on_cancel = function()
                cancelled = true
                Log.info("[KooboneDownload] 用户取消下载 fmd=" .. fmd_str)
            end,
            on_background = function()
                Log.info("[KooboneDownload] 后台运行下载 fmd=" .. fmd_str)
            end,
        }
        if ok_UIManager and UIManager then
            progress_dialog:show()
        end
        progress_dialog:setState{
            stage = "prepare",
            vol_name = tostring(vol_title),
            percent = 0,
        }
    end

    -- 桥接进度回调：同时驱动外部 callback、对话框和文件 IPC
    local function bridge_progress(stage, percent_or_bytes, msg, expected_size, download_bytes)
        if progress_dialog then
            local state = {
                stage = stage,
                percent = percent_or_bytes,
                message = msg or "",
                vol_name = vol_title_ipc,
            }
            if download_bytes and download_bytes > 0 then
                state.download_bytes = download_bytes
            end
            if expected_size and expected_size > 0 then
                state.expected_size = expected_size
            end
            progress_dialog:setState(state)
        end
        -- 子进程→父进程进度 IPC
        if progress_file then
            ipc_write_progress(progress_file, {
                current = download_bytes or 0,
                total = expected_size or 0,
                stage = stage,
                message = msg or "",
                vol_name = vol_title_ipc,
            })
        end
        if progress_callback then
            progress_callback(stage, percent_or_bytes, msg, expected_size, download_bytes)
        end
    end

    local function finish_dialog(success, err_msg)
        -- 写入最终状态到 IPC 文件
        if progress_file then
            ipc_write_progress(progress_file, {
                current = success and 1 or 0,
                total = 1,
                stage = success and "done" or (cancelled and "cancelled" or "error"),
                message = success and _("下载完成") or (err_msg or _("下载失败")),
                vol_name = vol_title_ipc,
            })
        end
        if progress_dialog then
            if success then
                progress_dialog:setState{
                    stage = "done",
                    percent = 100,
                    vol_name = vol_title_ipc,
                    message = _("下载完成"),
                }
            else
                progress_dialog:setState{
                    stage = cancelled and "cancelled" or "error",
                    percent = 0,
                    vol_name = vol_title_ipc,
                    message = err_msg or _("下载失败"),
                }
            end
            if ok_UIManager and UIManager then
                UIManager:scheduleIn(1.5, function()
                    if progress_dialog then
                        progress_dialog:close()
                    end
                end)
            end
        end
    end

    bridge_progress("prepare", 0, "准备中...")

    self:_lru_cleanup()

    if not vol or not vol.file_url or vol.file_url == "" then
        -- 优化: 优先从 bookshelf 本地缓存查（避免重复拉取 vol_list）
        if not vol and self.bookshelf then
            local local_vol = self.bookshelf:get_vol_by_fmd(fmd_str)
            if local_vol and local_vol.file_url and local_vol.file_url ~= "" then
                Log.info("[KooboneDownload] bookshelf 本地命中 vol: " .. fmd_str)
                vol = local_vol
            end
        end
        -- 本地没有或缺少 file_url，才走 HTTP 查询
        if (not vol or not vol.file_url or vol.file_url == "") and self.client then
            _state.setDownloadTask({ book_id = fmd_str, title = "查询卷信息", current = 0, total = 0 })
            bridge_progress("prepare", 5, "查询卷信息中...")
            local v, qerr = self.client:query_vol_info(fmd_str)
            if qerr or not v then
                _state.clearDownloadTask()
                cleanup_download()
                finish_dialog(false, "查询卷信息失败: " .. tostring(qerr or "未知"))
                return nil, nil, nil, "查询卷信息失败: " .. tostring(qerr or "未知")
            end
            vol = v
        elseif not vol then
            _state.clearDownloadTask()
            cleanup_download()
            finish_dialog(false, "缺少卷信息且 client 不可用")
            return nil, nil, nil, "缺少卷信息且 client 不可用"
        end
    end

    if not vol.file_url or vol.file_url == "" then
        _state.clearDownloadTask()
        cleanup_download()
        finish_dialog(false, "卷无下载链接 file_url")
        return nil, nil, nil, "卷无下载链接 file_url"
    end

    local file_md5 = vol.file_md5 or fmd_str
    local file_size = tonumber(vol.file_size) or 0
    local vol_title = vol.title or vol.vol_name or fmd_str

    _state.setDownloadTask({
        book_id = fmd_str,
        title = "下载 " .. tostring(vol_title),
        current = 0,
        total = file_size,
    })

    bridge_progress("download", 0, vol_title, file_size, 0)

    -- 统一取消检查（对话框 on_cancel 或 IPC cancel_file）
    local function is_cancelled()
        return cancelled or (cancel_file and ipc_check_cancel(cancel_file))
    end

    -- 检查是否已取消
    if is_cancelled() then
        _state.clearDownloadTask()
        cleanup_download()
        finish_dialog(false, _("下载已取消"))
        return nil, nil, nil, _("下载已取消")
    end

    -- 使用带进度的下载方法，实时回调进度（含 IPC 写入）
    local epub_path, dl_err = self:_download_epub_file_with_progress(
        vol, vol.file_url, file_size, file_md5,
        function(current, total, stage, message)
            bridge_progress("downloading", 0, message or "下载中", total, current)
        end,
        is_cancelled
    )
    if dl_err or not epub_path then
        _state.clearDownloadTask()
        cleanup_download()
        finish_dialog(false, "下载 EPUB 失败: " .. tostring(dl_err))
        return nil, nil, nil, "下载 EPUB 失败: " .. tostring(dl_err)
    end

    bridge_progress("extracting", 85, "解压中...", file_size, file_size)
    _state.updateDownloadProgress(0, 0, "解析 EPUB 中...")

    -- 再次检查取消
    if is_cancelled() then
        _state.clearDownloadTask()
        cleanup_download()
        finish_dialog(false, _("下载已取消"))
        return nil, nil, nil, _("下载已取消")
    end

    local extract_dir = self:_extract_dir(fmd_str, file_md5)
    local pages, perr = self:_parse_epub_pages(epub_path, extract_dir, file_md5, file_size)
    if perr or not pages then
        _state.clearDownloadTask()
        cleanup_download()
        finish_dialog(false, "解析 EPUB 失败: " .. tostring(perr))
        return nil, nil, nil, "解析 EPUB 失败: " .. tostring(perr)
    end

    bridge_progress("done", 100, "完成，共 " .. #pages .. " 页", file_size, file_size)
    _state.updateDownloadProgress(#pages, #pages, "完成")
    _state.clearDownloadTask()

    cleanup_download()

    -- 下载完成后更新书架状态（标记卷为已缓存）
    if self.bookshelf and vol then
        pcall(function()
            local cached_vol = self.bookshelf:get_vol_by_fmd(fmd_str)
            if cached_vol then
                cached_vol._local_downloaded = true
                cached_vol._local_pages = #pages
                cached_vol._local_last_read = os.time()
            end
        end)
        pcall(function()
            self.bookshelf:_save_shelf_cache()
        end)
    end

    finish_dialog(true)

    return vol, pages, extract_dir, nil
end

--- 只下载 EPUB 文件，不解压（用于 KOReader 直接打开）
-- @param vol 卷信息表（需包含 file_url, file_md5, file_size）
-- @param progress_dialog 进度对话框（可选，仅在同步模式生效）
-- @param plugin_ref 插件引用（用于检查取消状态）
-- @param ipc_opts 进度 IPC 选项（子进程模式）：
--   { progress_file = "...", cancel_file = "..." }
--   子进程模式下通过文件传递进度和取消信号给父进程
-- @return epub_path 下载后的 EPUB 文件路径，失败返回 nil
-- @return err 错误信息
function Download:download_epub_file(vol, progress_dialog, plugin_ref, ipc_opts)
    if not vol then
        return nil, "参数错误: vol 为空"
    end

    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then
        return nil, "参数错误: 缺少 file_md5"
    end

    ipc_opts = ipc_opts or {}
    local progress_file = ipc_opts.progress_file
    local cancel_file = ipc_opts.cancel_file

    -- 原子性检查1: 是否已下载（避免重复下载已完成的卷）
    local epub_path = self:_epub_path(fmd, vol.file_md5)
    if H.file_exists(epub_path) then
        local cur_size = self:_file_size(epub_path)
        if cur_size and cur_size > 1024 then
            Log.info("[KooboneDownload] 跳过已下载: fmd=" .. fmd .. " size=" .. tostring(cur_size))
            -- 更新书架状态
            if self.bookshelf then
                pcall(function()
                    local cached_vol = self.bookshelf:get_vol_by_fmd(fmd)
                    if cached_vol then cached_vol._local_downloaded = true end
                end)
            end
            return epub_path, nil
        end
    end

    -- 原子性检查2: 是否正在下载（避免并发下载同一卷）
    if self._active_downloads[fmd] then
        Log.info("[KooboneDownload] 跳过正在下载: fmd=" .. fmd)
        return nil, "该卷正在下载中，请稍后再试"
    end
    -- 检查是否在队列中
    for _, item in ipairs(self._download_queue) do
        if tostring(item.vol.file_md5 or item.vol.fmd) == fmd then
            Log.info("[KooboneDownload] 跳过已在队列中: fmd=" .. fmd)
            return nil, "该卷已在下载队列中"
        end
    end

    -- 标记为正在下载
    local vol_title = tostring(vol.title or vol.vol_name or fmd:sub(1, 8))
    self._active_downloads[fmd] = {
        vol = vol,
        title = vol_title,
        started_at = os.time(),
        source = progress_dialog and "manual" or "auto",
    }

    -- 检查是否有下载链接
    local file_url = vol.file_url
    if not file_url or file_url == "" then
        -- 优化: 优先从 bookshelf 本地缓存查（避免重复拉取 vol_list）
        if self.bookshelf then
            local local_vol = self.bookshelf:get_vol_by_fmd(fmd)
            if local_vol and local_vol.file_url and local_vol.file_url ~= "" then
                Log.info("[KooboneDownload] bookshelf 本地命中 vol(download_epub_file): " .. fmd)
                vol = local_vol
                file_url = vol.file_url
            end
        end
        -- 本地没有，才走 HTTP 查询
        if (not file_url or file_url == "") and self.client then
            local v, qerr = self.client:query_vol_info(fmd)
            if qerr or not v then
                self._active_downloads[fmd] = nil
                return nil, "查询卷信息失败: " .. tostring(qerr or "未知")
            end
            vol = v
            file_url = vol.file_url
        end
        if not file_url or file_url == "" then
            self._active_downloads[fmd] = nil
            return nil, "卷无下载链接 file_url"
        end
    end

    local file_md5 = vol.file_md5 or fmd
    local file_size = tonumber(vol.file_size) or 0
    local vol_title_str = tostring(vol.title or vol.vol_name or fmd:sub(1, 8))

    -- 进度回调函数
    -- 子进程模式下通过文件 IPC 传递进度给父进程（progress_dialog 在子进程中是 fork 副本，无法更新父进程 UI）
    -- 同步模式下直接更新 progress_dialog
    local function update_progress(current, total, stage, message)
        -- 子进程→父进程进度 IPC
        if progress_file then
            ipc_write_progress(progress_file, {
                current = current,
                total = total,
                stage = stage,
                message = message,
                vol_name = vol_title_str,
            })
        end
        -- 同步模式直接更新对话框（子进程模式下此调用作用于 fork 副本，不影响父进程）
        if progress_dialog and plugin_ref and not plugin_ref._download_cancelled then
            if stage then
                progress_dialog:setState{
                    stage = stage,
                    vol_name = vol_title_str,
                    download_bytes = current,
                    expected_size = total,
                    message = message,
                }
            end
        end
    end

    -- 检查是否取消（子进程通过文件 IPC 接收父进程的取消信号）
    local function check_cancelled()
        if cancel_file and ipc_check_cancel(cancel_file) then
            return true
        end
        if plugin_ref and plugin_ref._download_cancelled then
            return true
        end
        return false
    end

    Log.info("[KooboneDownload] 开始下载: " .. vol_title .. " fmd=" .. fmd)

    -- 调用内部下载方法（带进度回调）
    local epub_path, err = self:_download_epub_file_with_progress(vol, file_url, file_size, file_md5, update_progress, check_cancelled)

    -- 清除活跃下载标记
    self._active_downloads[fmd] = nil

    if err or not epub_path then
        return nil, err or "下载失败"
    end

    -- 更新书架状态
    if self.bookshelf then
        pcall(function()
            local cached_vol = self.bookshelf:get_vol_by_fmd(fmd)
            if cached_vol then
                cached_vol._local_downloaded = true
            end
            self.bookshelf:_save_shelf_cache()
        end)
    end

    return epub_path, nil
end

function Download:get_pages(fmd)
    if not fmd then return nil end
    local pages_idx = self:_pages_idx_path(fmd, nil)
    if not H.file_exists(pages_idx) then
        return nil
    end
    local text = read_file_text(pages_idx)
    if not text then return nil end
    local data = H.json_decode(text)
    if not data or type(data) ~= "table" then
        return nil
    end
    local pages = data.pages
    if type(pages) == "table" and #pages > 0 then
        return pages
    end
    if type(data) == "table" and #data > 0 then
        return data
    end
    return nil
end

function Download:delete_vol_cache(fmd, file_md5)
    if not fmd and not file_md5 then
        return false
    end
    local ok, err = pcall(function()
        local extract_dir = self:_extract_dir(fmd, file_md5)
        if H.dir_exists(extract_dir) then
            Log.info("[KooboneDownload] 删除卷缓存目录:", extract_dir)
            self:_safe_rmtree(extract_dir)
        end
        local epub_path = self:_epub_path(fmd, file_md5)
        if H.file_exists(epub_path) then
            Log.info("[KooboneDownload] 删除卷缓存 EPUB:", epub_path)
            os.remove(epub_path)
        end
    end)
    if not ok then
        Log.error("[KooboneDownload] delete_vol_cache 失败:", tostring(err))
        return false
    end
    return true
end

function Download:pre_download_pages(fmd, from_page_idx, page_count)
    if not fmd then return end
    page_count = tonumber(page_count) or 0
    if page_count <= 0 then return end

    local pages = self:get_pages(fmd)
    if pages then
        return
    end

    Async.run(function()
        local vol, pgs, edir, err = self:ensure_epub(fmd, nil)
        if err then
            Log.warn("[KooboneDownload] pre_download_pages ensure_epub 失败:", tostring(err))
        else
            Log.debug("[KooboneDownload] pre_download_pages 完成 fmd=" .. tostring(fmd)
                .. " pages=" .. tostring(pgs and #pgs or 0))
        end
    end, nil, { delay = 0.05, poll_interval = 0.25, timeout = 300 })
end

-- ============ 统一下载队列管理 ============

-- 检查卷是否正在下载
function Download:is_downloading(fmd)
    if not fmd then return false end
    return self._active_downloads[fmd] ~= nil
end

-- 检查卷是否已下载
function Download:is_downloaded(vol)
    if not vol then return false end
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return false end
    local epub_path = self:_epub_path(fmd, vol.file_md5)
    if H.file_exists(epub_path) then
        if self.bookshelf then
            pcall(function()
                local cached_vol = self.bookshelf:get_vol_by_fmd(fmd)
                if cached_vol then cached_vol._local_downloaded = true end
            end)
        end
        return true
    end
    return false
end

-- 获取队列状态
function Download:get_queue_status()
    local queued = #self._download_queue
    local active_count = 0
    for _, _ in pairs(self._active_downloads) do
        active_count = active_count + 1
    end
    return {
        queued = queued,
        active = active_count,
        total = queued + active_count,
        processing = self._queue_processing,
    }
end

-- 订阅队列状态变化
function Download:subscribe_queue(listener_id, callback)
    self._queue_listeners[listener_id] = callback
end

-- 取消订阅
function Download:unsubscribe_queue(listener_id)
    self._queue_listeners[listener_id] = nil
end

-- 通知队列状态变化
function Download:_notify_queue()
    local status = self:get_queue_status()
    for id, cb in pairs(self._queue_listeners) do
        local ok, err = pcall(cb, status)
        if not ok then
            Log.warn("[KooboneDownload] 队列通知失败 listener=" .. tostring(id) .. " err=" .. tostring(err))
        end
    end
end

-- 添加到下载队列
function Download:enqueue(vol, opts)
    if not vol then return false, "vol 为空" end
    
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return false, "缺少 file_md5" end
    
    opts = opts or {}
    local vol_title = tostring(vol.title or vol.vol_name or fmd:sub(1, 8))
    
    -- 检查是否已下载
    if self:is_downloaded(vol) then
        Log.info("[KooboneDownload] 跳过已下载: " .. vol_title .. " fmd=" .. fmd)
        return true, { skipped = true, reason = "already_downloaded" }
    end
    
    -- 检查是否正在下载
    if self._active_downloads[fmd] then
        Log.info("[KooboneDownload] 跳过正在下载: " .. vol_title .. " fmd=" .. fmd)
        return true, { skipped = true, reason = "already_downloading" }
    end
    
    -- 检查是否已在队列中
    for _, item in ipairs(self._download_queue) do
        if tostring(item.vol.file_md5 or item.vol.fmd) == fmd then
            Log.info("[KooboneDownload] 跳过已在队列中: " .. vol_title .. " fmd=" .. fmd)
            return true, { skipped = true, reason = "already_queued" }
        end
    end
    
    -- 添加到队列
    local item = {
        vol = vol,
        opts = opts,
        fmd = fmd,
        title = vol_title,
        added_at = os.time(),
    }
    table.insert(self._download_queue, item)
    Log.info("[KooboneDownload] 已加入下载队列: " .. vol_title .. " fmd=" .. fmd .. " 队列位置=" .. #self._download_queue)
    
    self:_notify_queue()
    
    -- 启动队列处理
    if not self._queue_processing then
        self:_process_queue()
    end
    
    return true, { queued = true }
end

-- 批量添加到下载队列
function Download:enqueue_batch(vols, opts)
    if not vols or #vols == 0 then return 0, 0 end
    
    local added = 0
    local skipped = 0
    local results = {}
    
    for _, vol in ipairs(vols) do
        local ok, result = self:enqueue(vol, opts)
        if ok and result and result.skipped then
            skipped = skipped + 1
        elseif ok then
            added = added + 1
        end
        if result then
            table.insert(results, result)
        end
    end
    
    Log.info("[KooboneDownload] 批量加入队列: 新增=" .. added .. " 跳过=" .. skipped)
    return added, skipped, results
end

-- 处理下载队列（串行处理，避免并发）
function Download:_process_queue()
    if self._queue_processing then return end
    if #self._download_queue == 0 then return end
    
    self._queue_processing = true
    self:_notify_queue()
    
    local function process_next()
        if #self._download_queue == 0 then
            self._queue_processing = false
            self:_notify_queue()
            Log.info("[KooboneDownload] 下载队列已清空")
            return
        end
        
        local item = table.remove(self._download_queue, 1)
        if not item then
            self._queue_processing = false
            self:_notify_queue()
            return
        end
        
        local fmd = item.fmd
        local vol = item.vol
        local opts = item.opts or {}
        local vol_title = item.title
        
        -- 检查是否已下载（可能在队列等待期间已被手动下载）
        if self:is_downloaded(vol) then
            Log.info("[KooboneDownload] 队列项已下载，跳过: " .. vol_title)
            process_next()
            return
        end
        
        -- 标记为正在下载（用于防止手动下载并发）
        self._active_downloads[fmd] = {
            vol = vol,
            title = vol_title,
            started_at = os.time(),
            source = "queue",
        }
        self:_notify_queue()
        
        Log.info("[KooboneDownload] 队列开始下载: " .. vol_title .. " fmd=" .. fmd)
        
        -- 使用 download_epub_file（含原子检查），但跳过已有的队列标记
        -- 因为我们已经检查过了，直接调用内部方法即可
        Async.run(
            function()
                -- 直接调用内部下载方法（已标记为 active，避免重复检查）
                local file_url = vol.file_url
                local expected_size = tonumber(vol.file_size) or 0
                local file_md5 = vol.file_md5 or fmd
                
                -- 如果没有 file_url，尝试查询
                if not file_url or file_url == "" then
                    -- 优化: 优先从 bookshelf 本地缓存查
                    if self.bookshelf then
                        local local_vol = self.bookshelf:get_vol_by_fmd(fmd)
                        if local_vol and local_vol.file_url and local_vol.file_url ~= "" then
                            file_url = local_vol.file_url
                            if expected_size == 0 then expected_size = tonumber(local_vol.file_size) or 0 end
                            if file_md5 == fmd and local_vol.file_md5 then file_md5 = local_vol.file_md5 end
                            Log.info("[KooboneDownload] 队列 bookshelf 本地命中: " .. fmd)
                        end
                    end
                    -- 本地没有，才走 HTTP 查询
                    if (not file_url or file_url == "") and self.client then
                        local v = self.client:query_vol_info(fmd)
                        if v then
                            file_url = v.file_url
                            if expected_size == 0 then expected_size = tonumber(v.file_size) or 0 end
                            if file_md5 == fmd and v.file_md5 then file_md5 = v.file_md5 end
                        end
                    end
                end
                
                if not file_url or file_url == "" then
                    return nil, "无下载链接"
                end
                
                return self:_download_epub_file(vol, file_url, expected_size, file_md5)
            end,
            function(ok, epub_path, err)
                -- 清除活跃下载标记
                self._active_downloads[fmd] = nil
                
                if not ok or not epub_path then
                    Log.warn("[KooboneDownload] 队列下载失败: " .. vol_title .. " err=" .. tostring(err or "未知"))
                    if opts.on_fail then
                        pcall(function() opts.on_fail(vol, err) end)
                    end
                else
                    Log.info("[KooboneDownload] 队列下载成功: " .. vol_title)
                    -- 更新书架状态
                    if self.bookshelf then
                        pcall(function()
                            local cached_vol = self.bookshelf:get_vol_by_fmd(fmd)
                            if cached_vol then
                                cached_vol._local_downloaded = true
                            end
                            self.bookshelf:_save_shelf_cache()
                        end)
                    end
                    if opts.on_success then
                        pcall(function() opts.on_success(vol, epub_path) end)
                    end
                end
                
                -- 通知进度
                self:_notify_queue()
                
                -- 继续处理队列
                process_next()
            end,
            { timeout = 600 }
        )
    end
    
    process_next()
end

-- 从队列中移除
function Download:remove_from_queue(fmd)
    if not fmd then return false end
    for i, item in ipairs(self._download_queue) do
        if tostring(item.vol.file_md5 or item.vol.fmd) == fmd then
            table.remove(self._download_queue, i)
            Log.info("[KooboneDownload] 已从队列移除: " .. tostring(item.title))
            self:_notify_queue()
            return true
        end
    end
    return false
end

-- 清空下载队列
function Download:clear_queue()
    local count = #self._download_queue
    self._download_queue = {}
    Log.info("[KooboneDownload] 已清空下载队列: " .. count .. " 项")
    self:_notify_queue()
    return count
end

-- ===== 公开 IPC 方法（供父进程调用）=====

-- 生成下载进度的 IPC 文件路径
function Download:ipc_paths(fmd)
    local base = self.EPUB_CACHE_DIR .. "/_ipc_" .. tostring(fmd or "unknown")
    return {
        progress_file = base .. "_progress.json",
        cancel_file = base .. "_cancel.flag",
    }
end

-- 父进程读取子进程写入的进度
function Download:ipc_read_progress(progress_file)
    return ipc_read_progress(progress_file)
end

-- 父进程发送取消信号
function Download:ipc_send_cancel(cancel_file)
    ipc_write_cancel(cancel_file)
end

-- 清理 IPC 文件
function Download:ipc_cleanup(paths)
    if not paths then return end
    ipc_cleanup(paths.progress_file, paths.cancel_file)
end

return Download
