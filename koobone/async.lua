local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_Log, Log = pcall(require, "koobone.logger")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local Async = {}

-- ============================================================
-- 活动句柄登记表 —— 让 handle.cancel 真正有人调用
-- ============================================================
-- 背景：Async.run 一直返回 handle（含 .cancel），但全仓库零个调用点接收它
-- （`grep -n "= Async.run("` 零命中）→ handle.cancel 是死代码。
-- 后果：凡是「打开界面 → 异步拉取 → 回填」的流程，用户中途关掉界面后，子进程仍会
-- 一路跑到 timeout（最长 60s），然后回填到一个已经死掉的 widget 上。
--
-- 这里把句柄集中登记，调用方不需要自己保存 handle：
--   opts.tag       可选，句柄归组名（默认 "default"），供 Async.cancel_tag 批量取消
--   opts.on_cancel 可选，被取消时回调。**取消后 on_done 不会再执行**，
--                  所以「本流程弹出的 loading 对话框」必须在这里关掉，
--                  否则界面会永久卡在 loading（墨水屏上等于假死）。
local _active = {}      -- id -> handle
local _next_id = 0

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

    -- 登记到活动表，并把 tag / on_cancel 冒泡到 handle 上（供 cancel_tag / cancel_all 使用）
    _next_id = _next_id + 1
    local handle_id = _next_id
    handle.id = handle_id
    handle.tag = opts.tag or "default"
    _active[handle_id] = handle

    -- 注销：句柄已终结（正常完成 / 取消 / 超时）。必须每条终结路径都调用，
    -- 否则活动表会无限增长（每次 Async.run 泄漏一个表项 + 一个已死句柄）。
    local function untrack()
        if _active[handle_id] == handle then
            _active[handle_id] = nil
        end
    end

    -- 收尸间隔（秒）/ 次数上限 / 读取宽限期（秒）
    local REAP_INTERVAL = 5
    local REAP_MAX_ATTEMPTS = 12
    local READ_GRACE = 2
    local data_seen_at = nil

    -- 异步收尸：关闭管道 fd 并让内核 reap 掉子进程，避免 fd 泄漏与僵尸进程。
    --
    -- ⚠️ 原实现是「先 readAllFromFD 排空管道 → 再 terminateSubProcess」，顺序是反的：
    -- readAllFromFD 是**阻塞读到 EOF**，子进程还在下载时它一秒都不返回 ——
    -- 也就是说「点取消」这个动作本身就会把 UI 冻到任务自然结束，取消按钮等于没有。
    -- 上游 koreader frontend/ui/trapper.lua:dismissableRunInSubprocess 的做法是
    -- 「先 terminateSubProcess，再交给 scheduleIn 异步收」，从不同步读。
    local function reap(pid_ref, fd_ref, attempt)
        attempt = attempt or 0
        if pid_ref and not ffiutil.isSubProcessDone(pid_ref) then
            if attempt >= REAP_MAX_ATTEMPTS then
                if ok_Log then
                    Log.warn("[async] 收尸重试超过 " .. REAP_MAX_ATTEMPTS
                        .. " 次仍未结束，放弃轮询；fd 交由进程退出时回收")
                end
                return
            end
            UIManager:scheduleIn(REAP_INTERVAL, function()
                reap(pid_ref, fd_ref, attempt + 1)
            end)
            return
        end
        -- 子进程已结束：此刻读管道会立即 EOF，顺带关闭自己这一端的 fd
        if fd_ref then
            pcall(ffiutil.readAllFromFD, fd_ref)
        end
    end

    -- 非阻塞地终止子进程，并把收尾交给异步收尸。「取消」与「超时」共用。
    local function abort_subprocess()
        local pid_ref, fd_ref = handle.pid, handle.fd
        handle.fd = nil   -- 句柄交给收尸函数，poll 不再碰它

        if pid_ref and not ffiutil.isSubProcessDone(pid_ref) then
            if type(ffiutil.terminateSubProcess) == "function" then
                pcall(ffiutil.terminateSubProcess, pid_ref)
            elseif ok_Log then
                Log.warn("[async] terminateSubProcess 不可用，改为等待子进程自然结束")
            end
        end

        reap(pid_ref, fd_ref)
    end

    handle.cancel = function()
        if handle._cancelled then return end   -- 幂等：连点两次取消不会重复收尸
        handle._cancelled = true
        untrack()
        abort_subprocess()
        -- ⚠️ 取消后 on_done 不会再执行（见 poll 末尾的 `not handle._cancelled` 守卫）。
        -- 因此「本流程自己弹出的 loading 对话框 / busy 提示」必须在 on_cancel 里关掉，
        -- 否则取消 = 界面永久卡在 loading。没有 loading 的流程可以不传。
        if type(opts.on_cancel) == "function" then
            pcall(opts.on_cancel)
        end
    end

    local function poll()
        if handle._cancelled then return end

        if os.difftime(os.time(), start_clock) > timeout then
            if ok_Log then Log.warn("[async] 子进程超时", timeout, "s，终止") end
            untrack()
            abort_subprocess()
            if on_done then on_done(false, nil, "async timeout") end
            return
        end

        local subprocess_done = ffiutil.isSubProcessDone(pid)
        local has_data = parent_read_fd
            and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0

        if has_data and not data_seen_at then
            data_seen_at = os.time()
        end

        -- readAllFromFD 是阻塞读到 EOF，只有两种情况才允许调用：
        --   ① 子进程已结束 —— 写端已关闭，read 会立即 EOF；
        --   ② 管道有数据、但子进程迟迟不结束且超过宽限期 —— payload 撑爆了管道容量，
        --      子进程正卡在 write 上，必须由父进程读走才能解开。
        -- 其余情况（子进程还在跑、还没写出东西）一律不读，否则界面会被冻住 ——
        -- 这正是「点取消却卡住」那个 bug 的同源问题。
        local should_read = has_data
            and (subprocess_done
                or os.difftime(os.time(), data_seen_at) >= READ_GRACE)

        if should_read or subprocess_done then
            local result_ok, result_val, result_err
            if should_read then
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
                -- 【无输出 = 无返回值的成功】（与 reading/async.lua 同语义）
                -- 子进程正常结束了、但一个字节都没往管道写。KOReader 的异步网络请求里
                -- 这经常发生：调用方只关心「做没做」，返回值本来就没意义（比如只写文件）。
                -- 判成失败会让一个已经成功的操作弹出「加载失败」——
                -- 而且这里的 err 文本（"subprocess exited without output"）对用户毫无意义。
                -- 调用方若真的需要结果，本来就会自己检查 `not result`（本仓库所有调用点都查）。
                result_ok, result_val = true, nil
            end

            -- 若此刻子进程尚未结束（走的是宽限期兜底路径），交给异步收尸，绝不阻塞等待。
            -- subprocess_done 为真时 reap 会立即返回，不产生额外开销。
            reap(pid, nil, 0)

            untrack()

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

-- ============================================================
-- 取消接口（配套上面的活动句柄登记表）
-- ============================================================

--- 取消全部活动子进程。用于插件 teardown（onExit）。
-- 注意：被取消的流程 on_done 不会执行，只有它们的 opts.on_cancel 会执行。
-- @return number 实际取消的句柄数
function Async.cancel_all()
    local n = 0
    local snapshot = {}
    for id, handle in pairs(_active) do
        snapshot[#snapshot + 1] = handle
        _active[id] = nil
    end
    for _i, handle in ipairs(snapshot) do
        if type(handle.cancel) == "function" then
            pcall(handle.cancel)
            n = n + 1
        end
    end
    return n
end

--- 按 tag 取消。用于「界面已关闭，本流程的异步结果不再需要」。
-- @param tag string|nil  nil 等价于 "default"
-- @return number 实际取消的句柄数
function Async.cancel_tag(tag)
    tag = tag or "default"
    local n = 0
    local snapshot = {}
    for id, handle in pairs(_active) do
        if handle.tag == tag then
            snapshot[#snapshot + 1] = handle
            _active[id] = nil
        end
    end
    for _i, handle in ipairs(snapshot) do
        if type(handle.cancel) == "function" then
            pcall(handle.cancel)
            n = n + 1
        end
    end
    return n
end

--- 当前活动子进程数（诊断 / 自检用）。
function Async.active_count()
    local n = 0
    for _ in pairs(_active) do n = n + 1 end
    return n
end

return Async
