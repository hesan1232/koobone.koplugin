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
        -- 【rename 要查】失败（权限 / 文件系统满 / 路径被占）时轮转根本没发生，
        -- 日志会一路增长到把分区占满，而且全程静默。此处只 print 不抛 ——
        -- 轮转失败不该把日志调用本身搞崩（本函数在 Log._flush 之后的写路径上调用）。
        local renamed, rename_err = os.rename(_log_file_path, old_path)
        if not renamed then
            print(string.format("%s 日志轮转失败（%s），日志将继续增长", LOG_MODULE, tostring(rename_err)))
        end
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
        -- ⚠️ write 返回值必须检查：写失败（磁盘满 / 句柄失效）时若不处理，之后每一次
        -- 日志都会对着一个坏句柄写、全部静默丢失。失败即丢弃句柄，下次调用会重开
        -- （见 ensure_open 里的 `if not _log_file_handle then`）。
        local write_ok, write_err = file:write(line .. "\n")
        if not write_ok then
            pcall(function() file:close() end)
            _log_file_handle = nil
            print(string.format("[%s] %s 日志写入失败: %s", LOG_MODULE, level, tostring(write_err)))
            return
        end
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


return Log
