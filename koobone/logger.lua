local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local Log = {}
local LOG_MODULE = "[KOOBONE]"
local MAX_LOG_SIZE = 512 * 1024

local _log_file_path = nil
local _log_file_handle = nil

local function ensure_log_path()
    if not _log_file_path then
        local data_dir = DataStorage:getDataDir() .. "/koobone"
        local mode = lfs.attributes(data_dir, "mode")
        if mode ~= "directory" then
            lfs.mkdir(data_dir)
        end
        _log_file_path = data_dir .. "/koobone.log"
    end
end

local function rotate_if_needed()
    ensure_log_path()
    local ok, attr = pcall(function()
        return lfs.attributes(_log_file_path)
    end)
    if ok and attr and attr.size and attr.size > MAX_LOG_SIZE then
        Log._flush()
        local old_path = _log_file_path .. ".old"
        os.remove(old_path)
        os.rename(_log_file_path, old_path)
    end
end

local function format_args(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" then
            table.insert(parts, v)
        else
            table.insert(parts, tostring(v))
        end
    end
    return table.concat(parts, " ")
end

function Log._flush()
    if _log_file_handle then
        pcall(function()
            _log_file_handle:flush()
            _log_file_handle:close()
        end)
        _log_file_handle = nil
    end
end

local _debug_enabled = false
function Log.init(settings)
    if settings and settings.should_show_debug_logs then
        local ok, val = pcall(function() return settings:should_show_debug_logs() end)
        if ok and val then
            _debug_enabled = true
        end
    end
    -- 预创建日志目录，避免首次写入时的竞态
    pcall(ensure_log_path)
end

function Log.is_debug_enabled()
    return _debug_enabled == true
end

local function ensure_open()
    ensure_log_path()
    if not _log_file_handle then
        rotate_if_needed()
        _log_file_handle = io.open(_log_file_path, "a")
    end
    return _log_file_handle
end

local function write_log(level, message)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("[%s] %s %s: %s", timestamp, LOG_MODULE, level, message)
    print(line)
    local file = ensure_open()
    if file then
        file:write(line .. "\n")
        -- 修复: 立即刷新到磁盘，否则崩溃时缓冲日志丢失，
        -- 导致用户看不到登录结果等关键信息
        file:flush()
    end
end

function Log.debug(...)
    if not _debug_enabled then return end
    local message = format_args(...)
    write_log("DEBUG", message)
end

function Log.info(...)
    local message = format_args(...)
    write_log("INFO", message)
end

function Log.warn(...)
    local message = format_args(...)
    write_log("WARN", message)
end

function Log.error(...)
    local message = format_args(...)
    write_log("ERROR", message)
end

function Log.get_log_file_path()
    ensure_log_path()
    return _log_file_path
end

function Log.clear_log()
    Log._flush()
    ensure_log_path()
    os.remove(_log_file_path)
    os.remove(_log_file_path .. ".old")
end

return Log
