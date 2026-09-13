local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local Log = require("koobone.logger")

local H = {}

function H.make_dir(path)
    if not path or path == "" then return end
    if H.dir_exists(path) then return end

    local parent = path:match("^(.*)[/\\]")
    if parent and parent ~= path then
        H.make_dir(parent)
    end

    Log.debug("创建目录: " .. path)
    local ok, err = lfs.mkdir(path)
    if not ok then
        Log.error("创建目录失败: " .. path .. ", 错误: " .. tostring(err))
    end
end

function H.dir_exists(path)
    local mode = lfs.attributes(path, "mode")
    return mode == "directory"
end

function H.file_exists(path)
    local mode = lfs.attributes(path, "mode")
    return mode == "file"
end

function H.delete_file(path)
    if H.file_exists(path) then
        Log.debug("删除文件: " .. path)
        os.remove(path)
    end
end

function H.delete_dir(path)
    if not H.dir_exists(path) then return end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = H.join_path(path, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                H.delete_dir(full_path)
            else
                H.delete_file(full_path)
            end
        end
    end
    lfs.rmdir(path)
end

function H.join_path(...)
    local args = {...}
    local path = args[1]
    for i = 2, #args do
        local part = args[i]
        if path:sub(-1) == "/" then
            path = path .. part
        else
            path = path .. "/" .. part
        end
    end
    return path
end

function H.is_str(value)
    return type(value) == "string"
end

function H.is_tbl(value)
    return type(value) == "table"
end

function H.trim(str)
    if not str then return "" end
    if type(str) ~= "string" then str = tostring(str) end
    -- 用括号包裹，丢弃 gsub 的第二个返回值（替换次数），
    -- 否则 H.trim 会返回 (string, count) 两个值，
    -- 导致 table.insert(t, H.trim(buf)) 被展开成 insert(t, string, count)
    -- 进而触发 "bad argument #2 to 'insert' (number expected, got string)"
    return (str:gsub("^%s+", ""):gsub("%s+$", ""))
end

function H.url_encode(str)
    if not str then return "" end
    if type(str) ~= "string" then str = tostring(str) end
    -- 同样用括号包裹，仅返回替换后的字符串
    return (str:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function H.json_decode(str)
    if not str then return nil end

    local ok, json = pcall(require, "json")
    if not ok then
        ok, json = pcall(require, "rapidjson")
    end

    if ok then
        local ok2, result = pcall(json.decode, str)
        if ok2 then
            return result
        end
    end

    Log.warn("JSON解码失败")
    return nil
end

function H.json_encode(obj)
    if not obj then return nil end

    local ok, json = pcall(require, "json")
    if not ok then
        ok, json = pcall(require, "rapidjson")
    end

    if ok then
        local ok2, result = pcall(json.encode, obj)
        if ok2 then
            return result
        end
    end

    Log.warn("JSON编码失败")
    return nil
end

function H.download_file(url, save_path)
    return H.download_file_with_headers(url, save_path, {})
end

function H.download_file_with_headers(url, save_path, headers)
    local ltn12 = require("ltn12")
    local default_ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    url = H.trim(url):gsub("\n", ""):gsub("\r", "")

    Log.debug("下载文件: " .. url .. " -> " .. save_path)

    local file = io.open(save_path, "wb")
    if not file then
        Log.error("无法打开文件: " .. save_path)
        return false, "无法打开文件: " .. save_path
    end

    local is_https = url:find("^https://") == 1
    local http_module

    if is_https then
        local ok_ssl, ssl = pcall(require, "ssl.https")
        if ok_ssl then
            http_module = ssl
        else
            file:close()
            Log.warn("HTTPS不可用，无法下载文件: " .. url)
            return false, "SSL不可用"
        end
    else
        http_module = require("socket.http")
    end

    local request_options = {
        url = url,
        sink = ltn12.sink.file(file),
        timeout = 30,
        headers = {
            ["User-Agent"] = default_ua,
            ["Referer"] = url:match("^(https?://[^/]+)") or "",
        },
    }

    for key, value in pairs(headers or {}) do
        request_options.headers[key] = value
    end

    local result, status = http_module.request(request_options)

    if status ~= 200 then
        H.delete_file(save_path)
        Log.error("HTTP请求失败: " .. tostring(status))
        return false, "HTTP请求失败: " .. tostring(status)
    end

    Log.debug("下载成功")
    return true
end

function H.download_string(url)
    local ltn12 = require("ltn12")
    local default_ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    Log.debug("下载字符串: " .. url)

    local data = {}

    local is_https = url:find("^https://") == 1
    local http_module

    if is_https then
        local ok_ssl, ssl = pcall(require, "ssl.https")
        if ok_ssl then
            http_module = ssl
        else
            Log.warn("HTTPS不可用，无法下载字符串: " .. url)
            return nil, "SSL不可用"
        end
    else
        http_module = require("socket.http")
    end

    local request_options = {
        url = url,
        sink = ltn12.sink.table(data),
        timeout = 30,
        headers = {
            ["User-Agent"] = default_ua,
            ["Referer"] = url:match("^(https?://[^/]+)") or "",
        },
    }

    local result, status = http_module.request(request_options)

    if status ~= 200 then
        Log.error("HTTP请求失败: " .. tostring(status))
        return nil, "HTTP请求失败: " .. tostring(status)
    end

    return table.concat(data)
end

function H.file_size(path)
    local size = lfs.attributes(path, "size")
    return size or 0
end

function H.get_data_dir()
    return DataStorage:getDataDir() .. "/koobone"
end

function H.get_cache_dir()
    return H.get_data_dir() .. "/cache"
end

function H.get_covers_dir()
    return H.get_cache_dir() .. "/covers"
end

function H.get_epub_dir()
    return H.get_data_dir() .. "/epub"
end

function H.get_pages_dir()
    return H.get_cache_dir() .. "/pages"
end

-- ============================================================
-- EPUB 缓存文件名生成（统一入口，供 download/bookshelf/shelf_view 共用）
-- ============================================================

--- 将任意字符串转为文件系统安全的文件名片段
-- 替换 Windows/Linux 禁止字符，去控制字符和首尾空白/点，折叠连续空格，截断长度
function H.safe_filename(name)
    if not name then return "" end
    if type(name) ~= "string" then name = tostring(name) end
    -- 替换 Windows / Linux 文件名禁止字符: \ / : * ? " < > |
    name = name:gsub('[\\/:*?"<>|]', "_")
    -- 去除控制字符
    name = name:gsub("%c", "")
    -- 折叠连续空白为单空格
    name = name:gsub("%s+", " ")
    -- 去除首尾空格和点（Windows 不允许结尾是 . 或空格）
    name = name:gsub("^[%s.]+", ""):gsub("[%s.]+$", "")
    -- 截断到 120 字符
    if #name > 120 then name = name:sub(1, 120) end
    return name
end

--- 生成封面缓存文件名（统一入口，保证 VFAT/Kindle 兼容）
-- fmd 可能是 file_md5（纯 hex，安全），也可能是 series_KMOE:27464 这种含冒号的字符串
-- Kindle VFAT 不接受 : 等字符，必须经过 safe_filename 处理
-- @param fmd 卷的 file_md5 或系列伪 fmd（如 "series_KMOE:xxx"）
-- @return safe_filename(fmd) .. ".jpg"
function H.cover_filename_for(fmd)
    return H.safe_filename(tostring(fmd or "unknown")) .. ".jpg"
end

--- 为 vol 生成系列子目录名（不含 epub_dir 前缀，不含首尾分隔符）
-- 规则: safe(vol.series or vol.vol_series or vol.series_id)
-- 若无系列信息，返回空字符串（表示直接放在 epub_dir 根目录）
function H.epub_subdir_for_vol(vol)
    if not vol then return "" end
    local series = vol.series or vol.vol_series or vol.series_id
    if not series or series == "" then return "" end
    local safe = H.safe_filename(series)
    return safe
end

--- 为 vol 生成新命名规则的 epub 文件名（不含目录，含 .epub 后缀）
-- 规则: {safe(vol_name or title)}.epub
-- 若 vol 为空或无 vol_name/title，回退到旧规则 {file_md5}.epub
function H.epub_filename_for_vol(vol, fmd, file_md5)
    local key_fmd = tostring(file_md5 or fmd or "")
    if key_fmd == "" then key_fmd = "unknown" end
    key_fmd = H.trim(key_fmd)
    local vol_name = vol and (vol.vol_name or vol.title) or nil
    if not vol_name or vol_name == "" then
        -- 回退到旧规则
        return key_fmd .. ".epub"
    end
    local safe = H.safe_filename(vol_name)
    if safe == "" then
        return key_fmd .. ".epub"
    end
    return safe .. ".epub"
end

--- 旧命名规则（纯 file_md5），仅用于兼容查找/删除
-- 旧版所有 epub 都在 epub_dir 根目录，命名为 {file_md5}.epub
function H.epub_legacy_filename(fmd, file_md5)
    local key = tostring(file_md5 or fmd or "unknown")
    return H.trim(key) .. ".epub"
end

--- 解析 vol 对应的已存在 EPUB 路径
-- 优先返回新命名路径（按系列分子目录）；若不存在则尝试旧命名（根目录），命中时自动迁移到新命名
-- 若都不存在，确保新路径的父目录存在，返回新路径供调用方写入下载文件
-- @param epub_dir EPUB 缓存根目录
-- @param vol 卷信息表（可为空）
-- @param fmd 字符串标识
-- @param file_md5 文件 MD5（可与 fmd 相同）
-- @return path 已存在或待写入的 epub 路径
function H.resolve_epub_path(epub_dir, vol, fmd, file_md5)
    local new_name = H.epub_filename_for_vol(vol, fmd, file_md5)
    local subdir = H.epub_subdir_for_vol(vol)
    local new_full_dir = epub_dir
    if subdir and subdir ~= "" then
        new_full_dir = H.join_path(epub_dir, subdir)
    end
    local new_path = H.join_path(new_full_dir, new_name)
    if H.file_exists(new_path) then
        return new_path
    end
    -- 兼容旧命名查找（旧版在 epub_dir 根目录）
    local legacy_name = H.epub_legacy_filename(fmd, file_md5)
    if legacy_name ~= new_name then
        local legacy_path = H.join_path(epub_dir, legacy_name)
        if H.file_exists(legacy_path) then
            -- 尝试迁移到新命名（先确保新目录存在）
            H.make_dir(new_full_dir)
            local ok_rename = pcall(function() os.rename(legacy_path, new_path) end)
            if H.file_exists(new_path) then
                return new_path
            end
            -- 迁移失败（文件被占用等），返回旧路径
            return legacy_path
        end
    end
    -- 新文件，确保父目录存在供调用方写入
    H.make_dir(new_full_dir)
    return new_path
end

-- ============================================================
-- 路径 / URL 工具
-- ============================================================

function H.path_normalize(p)
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

function H.join_url(base, rel)
    if not rel or rel == "" then return "" end
    if rel:find("^%a+://") then return rel end
    if rel:sub(1, 1) == "/" then
        local scheme_host = base:match("^(https?://[^/]+)") or ""
        return scheme_host .. rel
    end
    local base_dir = base:match("^(.*)/[^/]*$") or base
    return H.path_normalize(base_dir .. "/" .. rel)
end

function H.read_file_text(path)
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

-- ============================================================
-- 文件系统工具
-- ============================================================

function H.file_mtime(path)
    local mtime = lfs.attributes(path, "modification")
    return mtime or 0
end

function H.safe_rmtree(dir)
    H.delete_dir(dir)
end

function H.dir_size(dir)
    if not H.dir_exists(dir) then return 0 end
    local total = 0
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full = H.join_path(dir, entry)
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                total = total + H.dir_size(full)
            else
                total = total + H.file_size(full)
            end
        end
    end
    return total
end

-- ============================================================
-- LRU 缓存清理
-- ============================================================

function H.lru_cleanup(cache_dir, opts)
    opts = opts or {}
    local max_age = opts.max_age or (24 * 3600)
    local max_bytes = opts.max_bytes or (512 * 1024 * 1024)

    if not H.dir_exists(cache_dir) then
        return
    end
    local now_ts = os.time()
    local entries = {}
    local total_bytes = 0
    local ok, err = pcall(function()
        for name in lfs.dir(cache_dir) do
            if name ~= "." and name ~= ".." then
                local p = H.join_path(cache_dir, name)
                local attr_ok, attr = pcall(function() return lfs.attributes(p) end)
                if attr_ok and attr then
                    local atime = attr.access or attr.modification or now_ts
                    if now_ts - atime > max_age then
                        local mode = attr.mode
                        if mode == "directory" then
                            Log.info("[KooboneCache] 清理过期目录:", name)
                            H.safe_rmtree(p)
                        else
                            Log.info("[KooboneCache] 清理过期文件:", name)
                            os.remove(p)
                        end
                    else
                        local size = 0
                        if attr.mode == "directory" then
                            size = H.dir_size(p)
                        else
                            size = attr.size or 0
                        end
                        total_bytes = total_bytes + size
                        table.insert(entries, { atime = atime, size = size, path = p, name = name })
                    end
                end
            end
        end

        local limit_bytes = math.floor(max_bytes * 0.8)
        if total_bytes > max_bytes then
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
                        H.safe_rmtree(entry.path)
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

return H
