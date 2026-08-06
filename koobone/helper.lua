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

return H
