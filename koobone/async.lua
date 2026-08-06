local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_Log, Log = pcall(require, "koobone.logger")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local Async = {}

function Async.is_available()
    return ok_ffiutil
        and ffiutil
        and type(ffiutil.runInSubProcess) == "function"
        and type(ffiutil.writeToFD) == "function"
        and type(ffiutil.readAllFromFD) == "function"
        and type(ffiutil.getNonBlockingReadSize) == "function"
        and type(ffiutil.isSubProcessDone) == "function"
end

local function json_encode(v)
    if not ok_json or not json then return nil end
    local ok, s = pcall(function()
        if json.encode then return json.encode(v) end
        return json:encode(v)
    end)
    if ok then return s end
    return nil
end

local function json_decode(s)
    if not ok_json or not json then return nil end
    local ok, v = pcall(function()
        if json.decode then return json.decode(s) end
        return json:decode(s)
    end)
    if ok then return v end
    return nil
end

local function sanitize_err(err)
    local s = tostring(err or "unknown error")
    s = s:gsub("[%c]", " ")
    if #s > 1000 then s = s:sub(1, 1000) .. "..." end
    return s
end

local function run_sync(work_func, on_done, delay)
    if not ok_UIManager or not UIManager then
        local ok, result = pcall(work_func)
        if on_done then
            if ok then on_done(true, result, nil)
            else on_done(false, nil, sanitize_err(result)) end
        end
        return nil
    end
    UIManager:scheduleIn(delay or 0, function()
        local ok, result = pcall(work_func)
        if on_done then
            if ok then on_done(true, result, nil)
            else on_done(false, nil, sanitize_err(result)) end
        end
    end)
    return nil
end

function Async.run(work_func, on_done, opts)
    opts = opts or {}
    local poll_interval = opts.poll_interval or 0.125
    local timeout = opts.timeout or 60
    local delay = opts.delay or 0

    if not Async.is_available() then
        if ok_Log then Log.debug("[async] 子进程不可用，降级同步执行") end
        return run_sync(work_func, on_done, delay)
    end

    local function child_entry(pid, child_write_fd)
        local ok, result = pcall(work_func)
        local payload
        if ok then
            local enc = json_encode({ ok = true, result = result })
            payload = enc or '{"ok":true,"result":null}'
        else
            local enc = json_encode({ ok = false, err = sanitize_err(result) })
            payload = enc or '{"ok":false,"err":"encode failed"}'
        end
        pcall(ffiutil.writeToFD, child_write_fd, payload, true)
    end

    local pid, parent_read_fd = ffiutil.runInSubProcess(child_entry, true)
    if not pid then
        if ok_Log then Log.warn("[async] runInSubProcess 启动失败，降级同步") end
        return run_sync(work_func, on_done, delay)
    end

    local handle = { pid = pid, fd = parent_read_fd, _cancelled = false }
    local start_clock = os.time()

    local function cleanup(pid_ref, fd_ref)
        if fd_ref then
            pcall(ffiutil.readAllFromFD, fd_ref)
        end
        if pid_ref and not ffiutil.isSubProcessDone(pid_ref) then
            pcall(ffiutil.terminateSubProcess, pid_ref)
        end
    end

    handle.cancel = function()
        handle._cancelled = true
        cleanup(handle.pid, handle.fd)
        handle.fd = nil
    end

    local function poll()
        if handle._cancelled then return end

        if os.difftime(os.time(), start_clock) > timeout then
            if ok_Log then Log.warn("[async] 子进程超时", timeout, "s，终止") end
            cleanup(handle.pid, handle.fd)
            handle.fd = nil
            if on_done then on_done(false, nil, "async timeout") end
            return
        end

        local subprocess_done = ffiutil.isSubProcessDone(pid)
        local stuff_to_read = parent_read_fd
            and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0

        if subprocess_done or stuff_to_read then
            local result_ok, result_val, result_err
            if stuff_to_read then
                local ret_str = ffiutil.readAllFromFD(parent_read_fd)
                handle.fd = nil
                local decoded = ret_str and json_decode(ret_str)
                if type(decoded) == "table" then
                    if decoded.ok then
                        result_ok, result_val = true, decoded.result
                    else
                        result_ok, result_err = false, decoded.err or "unknown error"
                    end
                else
                    if subprocess_done then
                        result_ok, result_val = true, nil
                    else
                        result_ok, result_err = false, "malformed subprocess output"
                    end
                end
            else
                if parent_read_fd then
                    pcall(ffiutil.readAllFromFD, parent_read_fd)
                    handle.fd = nil
                end
                result_ok, result_err = false, "subprocess exited without output"
            end

            if not subprocess_done then
                local collect_pid = pid
                local collect
                collect = function()
                    if not ffiutil.isSubProcessDone(collect_pid) then
                        UIManager:scheduleIn(1, collect)
                    end
                end
                UIManager:scheduleIn(1, collect)
            end

            if on_done and not handle._cancelled then
                if result_ok then
                    on_done(true, result_val, nil)
                else
                    on_done(false, nil, result_err)
                end
            end
        else
            UIManager:scheduleIn(poll_interval, poll)
        end
    end

    UIManager:scheduleIn(delay, poll)
    return handle
end

return Async
