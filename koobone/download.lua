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
                -- 更新进度
                if progress_callback then
                    progress_callback(downloaded, expected, "downloading", string.format("下载中 %s/%s",
                        format_size(downloaded), format_size(expected)))
                end
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

    if cancelled then
        return nil, "下载已取消"
    end

    if not ok_trans then
        return nil, "HTTP连接异常: " .. tostring(result1)
    end

    local code = result2
    if type(code) ~= "number" or code < 200 or code >= 300 then
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
    if H.file_exists(tmp_path) then
        pcall(os.remove, tmp_path)
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
    Log.info("[KooboneDownload] 策略列表(无进度): " .. table.concat(strat_names, ", ") .. " fmd=" .. fmd)
    for si, strat in ipairs(strategies) do
        Log.info("[KooboneDownload] 使用策略 " .. strat.name .. " (第" .. si .. "/" .. #strategies .. "个) verify=" .. tostring(strat.verify))
        for attempt = 1, 3 do
            if H.file_exists(tmp_path) then
                pcall(os.remove, tmp_path)
            end
            _state.updateDownloadProgress(0, expected_size, "下载策略:" .. strat.name .. " 尝试" .. attempt .. "/3")
            -- 使用 pcall 防止异常中断策略循环
            local ok_call, size, err = pcall(function()
                return self:_do_http_download(strat.url, tmp_path, expected_size, strat.verify, fmd)
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
    local request_options = {
        method = "HEAD",
        url = url,
        sink = ltn12.sink.null(),
        headers = response_headers,
        timeout = 30,
    }

    if is_https and transport == https then
        request_options.mode = "client"
        request_options.protocol = "tlsv1_2"
        request_options.verify = "peer"
        request_options.options = "all"
    end

    local ok, result = pcall(transport.request, request_options)
    if not ok then
        Log.warn("[KooboneDownload] HEAD request failed: " .. tostring(result))
        return nil
    end

    local code = result
    if type(code) ~= "number" or code < 200 or code >= 300 then
        Log.warn("[KooboneDownload] HEAD request returned HTTP " .. tostring(code))
        return nil
    end

    -- 从响应头中提取 Content-Length
    local content_length = response_headers["content-length"]
    if content_length then
        local size = tonumber(content_length)
        if size and size > 0 then
            Log.info("[KooboneDownload] HEAD request got Content-Length: " .. size)
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
    if H.file_exists(tmp_path) then
        pcall(os.remove, tmp_path)
    end

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
    for si, strat in ipairs(strategies) do
        Log.info("[KooboneDownload] 使用策略 " .. strat.name .. " (第" .. si .. "/" .. #strategies .. "个) verify=" .. tostring(strat.verify))
        -- 检查取消
        if cancel_check and cancel_check() then
            Log.info("[KooboneDownload] 下载被取消，跳过后续策略")
            if progress_callback then
                progress_callback(0, expected_size, "cancelled", "下载已取消")
            end
            if H.file_exists(tmp_path) then
                pcall(os.remove, tmp_path)
            end
            return nil, "下载已取消"
        end

        for attempt = 1, 3 do
            -- 再次检查取消
            if cancel_check and cancel_check() then
                Log.info("[KooboneDownload] 下载被取消(尝试" .. attempt .. ")")
                if progress_callback then
                    progress_callback(0, expected_size, "cancelled", "下载已取消")
                end
                if H.file_exists(tmp_path) then
                    pcall(os.remove, tmp_path)
                end
                return nil, "下载已取消"
            end

            if H.file_exists(tmp_path) then
                pcall(os.remove, tmp_path)
            end

            if progress_callback then
                progress_callback(0, expected_size, "downloading", "下载策略:" .. strat.name .. " 尝试" .. attempt .. "/3")
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

function Download:_extract_zip_shell(epub_path, extract_dir)
    local epub_norm = epub_path:gsub("\\", "/")
    local extract_norm = extract_dir:gsub("\\", "/")
    local cmd
    if package.config:sub(1, 1) == "\\" then
        cmd = string.format('unzip -o -q "%s" -d "%s" 2>nul', epub_norm, extract_norm)
    else
        cmd = string.format('unzip -o -q "%s" -d "%s" 2>/dev/null', epub_norm, extract_norm)
    end
    local ok = os.execute(cmd)
    if ok == 0 or ok == true then
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

function Download:ensure_epub(fmd_or_vol, progress_callback)
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

    -- 修复1: 重复下载保护 - 同一卷正在下载时返回 in_progress
    local key = self:_cache_key(fmd_str, vol and vol.file_md5 or nil)
    if self._active_downloads[key] then
        Log.info("[KooboneDownload] 卷正在下载中: " .. key)
        if progress_callback then
            progress_callback("prepare", 0, "该卷正在下载中，请稍候...")
        end
        -- 等待已有下载完成
        local wait_start = os.clock()
        local timeout = 300 -- 5 分钟超时
        while self._active_downloads[key] and (os.clock() - wait_start) < timeout do
            os.execute("sleep 0.5")
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
    local progress_dialog = nil
    local cancelled = false
    if ok_DLProgress and DownloadProgress then
        local vol_title = (vol and (vol.title or vol.vol_name)) or fmd_str
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

    -- 桥接进度回调：同时驱动外部 callback 和对话框
    local function bridge_progress(stage, percent_or_bytes, msg, expected_size, download_bytes)
        if progress_dialog then
            local state = {
                stage = stage,
                percent = percent_or_bytes,
                message = msg or "",
                vol_name = (vol and (vol.title or vol.vol_name)) or fmd_str,
            }
            if download_bytes and download_bytes > 0 then
                state.download_bytes = download_bytes
            end
            if expected_size and expected_size > 0 then
                state.expected_size = expected_size
            end
            progress_dialog:setState(state)
        end
        if progress_callback then
            progress_callback(stage, percent_or_bytes, msg, expected_size, download_bytes)
        end
    end

    local function finish_dialog(success, err_msg)
        if progress_dialog then
            if success then
                progress_dialog:setState{
                    stage = "done",
                    percent = 100,
                    vol_name = (vol and (vol.title or vol.vol_name)) or fmd_str,
                    message = _("下载完成"),
                }
            else
                progress_dialog:setState{
                    stage = cancelled and "cancelled" or "error",
                    percent = 0,
                    vol_name = (vol and (vol.title or vol.vol_name)) or fmd_str,
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
        if self.client then
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
        else
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

    bridge_progress("download", 10, vol_title, file_size, 0)

    -- 检查是否已取消
    if cancelled then
        _state.clearDownloadTask()
        cleanup_download()
        finish_dialog(false, _("下载已取消"))
        return nil, nil, nil, _("下载已取消")
    end

    local epub_path, dl_err = self:_download_epub_file(vol, vol.file_url, file_size, file_md5)
    if dl_err or not epub_path then
        _state.clearDownloadTask()
        cleanup_download()
        finish_dialog(false, "下载 EPUB 失败: " .. tostring(dl_err))
        return nil, nil, nil, "下载 EPUB 失败: " .. tostring(dl_err)
    end

    bridge_progress("extracting", 85, "解压中...", file_size, file_size)
    _state.updateDownloadProgress(0, 0, "解析 EPUB 中...")

    -- 再次检查取消
    if cancelled then
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
-- @param progress_dialog 进度对话框（可选）
-- @param plugin_ref 插件引用（用于检查取消状态）
-- @return epub_path 下载后的 EPUB 文件路径，失败返回 nil
-- @return err 错误信息
function Download:download_epub_file(vol, progress_dialog, plugin_ref)
    if not vol then
        return nil, "参数错误: vol 为空"
    end

    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then
        return nil, "参数错误: 缺少 file_md5"
    end

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
        -- 尝试从 client 查询
        if self.client then
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

    -- 进度回调函数
    -- 注意: 不传 percent 字段，让 setState 根据 download_bytes/expected_size 自己计算
    -- 否则 setState 会误判 percent 为字节数，导致进度条始终显示 0%
    local function update_progress(current, total, stage, message)
        if progress_dialog and plugin_ref and not plugin_ref._download_cancelled then
            if stage then
                progress_dialog:setState{
                    stage = stage,
                    vol_name = tostring(vol.title or fmd),
                    download_bytes = current,
                    expected_size = total,
                    message = message,
                }
            end
        end
    end

    -- 检查是否取消
    local function check_cancelled()
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
                    if self.client then
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

return Download
