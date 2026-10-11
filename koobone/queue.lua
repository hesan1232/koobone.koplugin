local Log = require("koobone.logger")

local M = {}

function M.create()
    return {
        _download_queue = {},
        _active_downloads = {},
        _queue_processing = false,
        _queue_processing_at = 0,
    }
end

-- 「队列正在处理」的判据。
--
-- 【为什么不能只看布尔】Async 被取消时 on_done 不会执行（见 koobone/async.lua 的 poll
-- 守卫 `if handle._cancelled then return end`），纯布尔标志一旦没被复位就会永久卡在 true ——
-- 后果是所有 enqueue 都被 `if not state._queue_processing then M._process(...) end`
-- 静默跳过（表现：点「下载」毫无反应，只能重启 KOReader）。
-- _process 里已用 opts.on_cancel 补做清理（第一道防线），这里是第二道：
-- 时间戳超时未刷新即视为僵死，强制接管。
local QUEUE_STALE_SECONDS = 15 * 60   -- 单个条目的 async timeout 是 600s，留 1.5 倍余量
local function is_processing(state)
    if not state._queue_processing then return false end
    local started_at = state._queue_processing_at or 0
    if started_at > 0 and (os.time() - started_at) < QUEUE_STALE_SECONDS then
        return true
    end
    Log.warn("[KooboneQueue] _queue_processing 已僵死超过 " .. QUEUE_STALE_SECONDS
        .. "s（疑似取消路径未复位），强制接管")
    state._queue_processing = false
    state._queue_processing_at = 0
    return false
end

function M.enqueue(state, vol, opts, callbacks)
    if not vol then return false, "vol 为空" end

    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return false, "缺少 file_md5" end

    opts = opts or {}
    local vol_title = tostring(vol.title or vol.vol_name or fmd:sub(1, 8))

    if callbacks and callbacks.is_downloaded and callbacks.is_downloaded(vol) then
        Log.info("[KooboneQueue] 跳过已下载: " .. vol_title .. " fmd=" .. fmd)
        return true, { skipped = true, reason = "already_downloaded" }
    end

    if state._active_downloads[fmd] then
        Log.info("[KooboneQueue] 跳过正在下载: " .. vol_title .. " fmd=" .. fmd)
        return true, { skipped = true, reason = "already_downloading" }
    end

    for _, item in ipairs(state._download_queue) do
        if tostring(item.vol.file_md5 or item.vol.fmd) == fmd then
            Log.info("[KooboneQueue] 跳过已在队列中: " .. vol_title .. " fmd=" .. fmd)
            return true, { skipped = true, reason = "already_queued" }
        end
    end

    local item = {
        vol = vol,
        opts = opts,
        fmd = fmd,
        title = vol_title,
        added_at = os.time(),
    }
    table.insert(state._download_queue, item)
    Log.info("[KooboneQueue] 已加入下载队列: " .. vol_title .. " fmd=" .. fmd .. " 队列位置=" .. #state._download_queue)

    if not is_processing(state) then
        M._process(state, callbacks)
    end

    return true, { queued = true }
end

function M.enqueue_batch(state, vols, opts, callbacks)
    if not vols or #vols == 0 then return 0, 0 end

    local added = 0
    local skipped = 0
    local results = {}

    for _, vol in ipairs(vols) do
        local ok, result = M.enqueue(state, vol, opts, callbacks)
        if ok and result and result.skipped then
            skipped = skipped + 1
        elseif ok then
            added = added + 1
        end
        if result then
            table.insert(results, result)
        end
    end

    Log.info("[KooboneQueue] 批量加入队列: 新增=" .. added .. " 跳过=" .. skipped)
    return added, skipped, results
end

function M._process(state, callbacks)
    if is_processing(state) then return end
    if #state._download_queue == 0 then return end

    state._queue_processing = true
    state._queue_processing_at = os.time()

    local function process_next()
        -- 每处理一项都刷新时间戳：僵死窗口只需覆盖「单个条目的下载时长」（async
        -- timeout 600s），而不是整个队列（长队列可能几十分钟），否则会被误判为僵死。
        state._queue_processing_at = os.time()
        if #state._download_queue == 0 then
            state._queue_processing = false
            state._queue_processing_at = 0
            Log.info("[KooboneQueue] 下载队列已清空")
            return
        end

        local item = table.remove(state._download_queue, 1)
        if not item then
            state._queue_processing = false
            state._queue_processing_at = 0
            return
        end

        local fmd = item.fmd
        local vol = item.vol
        local opts = item.opts or {}
        local vol_title = item.title

        if callbacks and callbacks.is_downloaded and callbacks.is_downloaded(vol) then
            Log.info("[KooboneQueue] 队列项已下载，跳过: " .. vol_title)
            process_next()
            return
        end

        state._active_downloads[fmd] = {
            vol = vol,
            title = vol_title,
            started_at = os.time(),
            source = "queue",
        }

        Log.info("[KooboneQueue] 队列开始下载: " .. vol_title .. " fmd=" .. fmd)

        local download_fn = callbacks and callbacks.download
        local async_run = callbacks and callbacks.async_run

        if not download_fn or not async_run then
            Log.warn("[KooboneQueue] 缺少下载回调，无法处理队列项: " .. vol_title)
            state._active_downloads[fmd] = nil
            process_next()
            return
        end

        async_run(
            function()
                return download_fn(vol, fmd)
            end,
            function(ok, epub_path, err)
                state._active_downloads[fmd] = nil

                if not ok or not epub_path then
                    Log.warn("[KooboneQueue] 队列下载失败: " .. vol_title .. " err=" .. tostring(err or "未知"))
                    if callbacks.on_fail then
                        pcall(function() callbacks.on_fail(vol, err) end)
                    end
                    if opts.on_fail then
                        pcall(function() opts.on_fail(vol, err) end)
                    end
                else
                    Log.info("[KooboneQueue] 队列下载成功: " .. vol_title)
                    if callbacks.on_success then
                        pcall(function() callbacks.on_success(vol, epub_path) end)
                    end
                    if opts.on_success then
                        pcall(function() opts.on_success(vol, epub_path) end)
                    end
                end

                process_next()
            end,
            {
                timeout = 600,
                -- 【取消路径必须自己收尾】Async 被取消时 on_done 不会执行，而
                -- _active_downloads / _queue_processing 的清理全写在 on_done 里。
                -- 主插件退出时会 Async.cancel_all()，不补这一句就会留下
                -- _queue_processing == true 的僵死状态（后续 enqueue 全被静默跳过）。
                on_cancel = function()
                    state._active_downloads[fmd] = nil
                    state._queue_processing = false
                    state._queue_processing_at = 0
                end,
            }
        )
    end

    process_next()
end

function M.remove_from_queue(state, fmd)
    if not fmd then return false end
    for i, item in ipairs(state._download_queue) do
        if tostring(item.vol.file_md5 or item.vol.fmd) == fmd then
            table.remove(state._download_queue, i)
            Log.info("[KooboneQueue] 已从队列移除: " .. tostring(item.title))
            return true
        end
    end
    return false
end

function M.is_downloading(state, fmd)
    if not fmd then return false end
    return state._active_downloads[fmd] ~= nil
end

-- 是否在 pending 队列里（尚未开始下载，正在排队）
-- 注意：队列数组的字段名是 `_download_queue`。此前这里错读成 `state.pending`，
-- 该字段从未定义 → 恒返回 false，导致 main.lua 预下载的去重检查形同虚设。
function M.is_enqueued(state, fmd)
    if not fmd or not state._download_queue or #state._download_queue == 0 then return false end
    for _, item in ipairs(state._download_queue) do
        local f = tostring(item.vol and (item.vol.file_md5 or item.vol.fmd) or "")
        if f == fmd then return true end
    end
    return false
end

return M