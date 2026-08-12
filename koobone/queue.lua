local Log = require("koobone.logger")

local M = {}

function M.create()
    return {
        _download_queue = {},
        _active_downloads = {},
        _queue_processing = false,
        _queue_listeners = {},
    }
end

function M.get_status(state)
    local queued = #state._download_queue
    local active_count = 0
    for _ in pairs(state._active_downloads) do
        active_count = active_count + 1
    end
    return {
        queued = queued,
        active = active_count,
        total = queued + active_count,
        processing = state._queue_processing,
    }
end

function M.subscribe(state, listener_id, callback)
    state._queue_listeners[listener_id] = callback
end

function M.unsubscribe(state, listener_id)
    state._queue_listeners[listener_id] = nil
end

function M._notify(state)
    local status = M.get_status(state)
    for id, cb in pairs(state._queue_listeners) do
        local ok, err = pcall(cb, status)
        if not ok then
            Log.warn("[KooboneQueue] 通知失败 listener=" .. tostring(id) .. " err=" .. tostring(err))
        end
    end
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

    M._notify(state)

    if not state._queue_processing then
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
    if state._queue_processing then return end
    if #state._download_queue == 0 then return end

    state._queue_processing = true
    M._notify(state)

    local function process_next()
        if #state._download_queue == 0 then
            state._queue_processing = false
            M._notify(state)
            Log.info("[KooboneQueue] 下载队列已清空")
            return
        end

        local item = table.remove(state._download_queue, 1)
        if not item then
            state._queue_processing = false
            M._notify(state)
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
        M._notify(state)

        Log.info("[KooboneQueue] 队列开始下载: " .. vol_title .. " fmd=" .. fmd)

        local download_fn = callbacks and callbacks.download
        local async_run = callbacks and callbacks.async_run

        if not download_fn or not async_run then
            Log.warn("[KooboneQueue] 缺少下载回调，无法处理队列项: " .. vol_title)
            state._active_downloads[fmd] = nil
            M._notify(state)
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

                M._notify(state)
                process_next()
            end,
            { timeout = 600 }
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
            M._notify(state)
            return true
        end
    end
    return false
end

function M.clear_queue(state)
    local count = #state._download_queue
    state._download_queue = {}
    Log.info("[KooboneQueue] 已清空下载队列: " .. count .. " 项")
    M._notify(state)
    return count
end

function M.is_downloading(state, fmd)
    if not fmd then return false end
    return state._active_downloads[fmd] ~= nil
end

-- 是否在 pending 队列里（尚未开始下载，正在排队）
function M.is_enqueued(state, fmd)
    if not fmd or not state.pending or #state.pending == 0 then return false end
    for _, item in ipairs(state.pending) do
        local f = tostring(item.vol and (item.vol.file_md5 or item.vol.fmd) or "")
        if f == fmd then return true end
    end
    return false
end

function M.get_active_downloads(state)
    return state._active_downloads
end

return M