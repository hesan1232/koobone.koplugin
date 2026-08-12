local M = {
    _settings_ref = nil,  -- 与 settings 联动，用于持久化下载状态
    current_comic = nil,
    current_page = 0,
    shelf_vols_cache = nil,
    shelf_cache_ttl = 30,
    download_task = nil,
    is_downloading = false,   -- 用户主动下载（阻塞性）
    pre_downloading = false,  -- 后台预下载（非阻塞）
    pre_download_triggered = false,  -- 防重入：当前阅读上下文已触发过预下载
    download_history = {},    -- 最近10条下载历史
    progress_upload_task = nil,
    last_read_time = {},
    -- 目录缓存：key=series_id, value={ ts=过期时间戳, vols={...} }
    directory_cache = {},
    DIRECTORY_CACHE_TTL = 24 * 60 * 60,  -- 24小时（与 fanqie 一致）
    -- 章节下载索引缓存：key=series_id, value={ ts=过期时间戳, downloaded={fmd=true, ...} }
    chapter_index_cache = {},
    CHAPTER_INDEX_CACHE_TTL = 24 * 60 * 60,
}

local DOWNLOAD_HISTORY_MAX = 10  -- 与用户确认：保留最近10条

-- ============================================================
-- 启动初始化：与 settings 联动，恢复下载状态
-- ============================================================
function M.bindSettings(settings)
    M._settings_ref = settings
    M.loadDownloadState()
end

function M.loadDownloadState()
    local s = M._settings_ref
    if not s then return end

    -- 1. 恢复 download_task
    local task = s.getDownloadTask and s:getDownloadTask() or nil
    if task and task.is_downloading then
        -- 启动时发现标记为正在下载的任务 = 异常中断的未完成任务
        -- 标记 interrupted 后归入历史，不再恢复到"正在下载"状态
        task.is_downloading = false
        task.interrupted = true
        task.interrupted_at = os.time()
        task.finish_ts = task.finish_ts or os.time()
        M._pushDownloadHistory(task)
        M.download_task = nil
        M.is_downloading = false
    else
        M.download_task = task
        M.is_downloading = task and true or false
    end

    -- 2. 恢复 download_history
    local history = s.getDownloadHistory and s:getDownloadHistory() or nil
    if type(history) == "table" and #history > 0 then
        M.download_history = {}
        for _, h in ipairs(history) do
            table.insert(M.download_history, h)
        end
    end
    M.pre_downloading = false
    M.pre_download_triggered = false
end

-- Batch flush：延迟 3s 聚合写盘，避免下载中频繁 setDownloadTask/clearDownloadTask
-- → 每一次都 s:flush() → settings 触发 setDirty → 局刷
-- 3s 内把 N 次 task / history 更新聚合成 1 次写盘，有效减少局刷
local _flush_scheduled = false
local _dirty_since = 0
local _FLUSH_DELAY = 3  -- 3 秒聚合窗口
local function schedule_flush_later()
    _dirty_since = os.time()
    if _flush_scheduled then return end
    if not (type(UIManager) == "table" and UIManager.scheduleIn) then
        local s = M._settings_ref
        if s and s.flush then pcall(function() s:flush() end) end
        return
    end
    _flush_scheduled = true
    UIManager:scheduleIn(_FLUSH_DELAY, function()
        _flush_scheduled = false
        local s = M._settings_ref
        if not s then return end
        -- 再检查一次：如果在 flush 前又有新的修改，再调度一次
        local now = os.time()
        if _dirty_since > 0 and (now - _dirty_since) < _FLUSH_DELAY then
            -- 在窗口内还有修改，直接 flush 并重置窗口
            _dirty_since = 0
        end
        if s.flush then
            local ok_f, err_f = pcall(function() s:flush() end)
            if not ok_f then
                pcall(function() require("logger"):warn("state batch flush settings failed:", tostring(err_f)) end)
            end
        end
    end)
end

function M.persist_download_task()
    local s = M._settings_ref
    if not s or not s.setDownloadTask then return end
    local task = M.download_task
    if task then
        local safe = {}
        for k, v in pairs(task) do
            local t = type(v)
            if t == "string" or t == "number" or t == "boolean" then
                safe[k] = v
            end
        end
        pcall(function() s:setDownloadTask(safe) end)
    else
        pcall(function() s:setDownloadTask(nil) end)
    end
    -- 全部走 batch flush：2s 内聚合 1 次写盘
    schedule_flush_later()
end

function M.persist_download_history()
    local s = M._settings_ref
    if not s or not s.setDownloadHistory then return end
    local safe_list = {}
    for _, h in ipairs(M.download_history) do
        local safe = {}
        for k, v in pairs(h) do
            local t = type(v)
            if t == "string" or t == "number" or t == "boolean" then
                safe[k] = v
            end
        end
        table.insert(safe_list, safe)
    end
    pcall(function() s:setDownloadHistory(safe_list) end)
    -- 同样走 batch flush
    schedule_flush_later()
end

-- ============================================================
-- 当前漫画 / 当前页
-- ============================================================
function M.getCurrentComic()
    return M.current_comic
end

function M.setCurrentComic(c)
    M.current_comic = c
    -- 切换到新漫画上下文，重置预下载重入标志
    M.pre_download_triggered = false
end

function M.getCurrentPage()
    return M.current_page
end

function M.setCurrentPage(p)
    M.current_page = p or 0
end

-- ============================================================
-- 书架缓存（兼容旧接口，bookshelf 实际以自身内存缓存为主）
-- ============================================================
function M.getShelfVols()
    if M.shelf_vols_cache then
        return M.shelf_vols_cache.data
    end
    return nil
end

function M.setShelfVols(data)
    M.shelf_vols_cache = {
        ts = os.time(),
        data = data,
    }
end

function M.isShelfCacheValid()
    if not M.shelf_vols_cache then
        return false
    end
    local elapsed = os.difftime(os.time(), M.shelf_vols_cache.ts)
    return elapsed < M.shelf_cache_ttl
end

function M.invalidateShelfCache()
    M.shelf_vols_cache = nil
end

function M.clearShelfVols()
    M.shelf_vols_cache = nil
end

-- ============================================================
-- 下载任务（区分手动下载 vs 预下载）
-- ============================================================
-- 防止连续多次 setDownloadTask(nil)/clearDownloadTask 触发大量写盘
local _task_set_cooldown_until = 0
function M.setDownloadTask(t)
    -- 防抖：如果在 100ms 内重复设置相同状态（主要是 nil），跳过写盘
    local now = os.clock()
    if t == nil and M.download_task == nil and (now < _task_set_cooldown_until) then
        return  -- 相同状态且在冷却窗口内，直接跳过
    end
    _task_set_cooldown_until = now + 0.1  -- 100ms 冷却窗口

    local old_task = M.download_task
    M.download_task = t
    if t then
        t.is_downloading = true
        M.is_downloading = true
    else
        -- 如果是手动下载结束，把前一个 download_task 推入历史
        if old_task and M.is_downloading and not M.pre_downloading then
            local finished = old_task
            finished.is_downloading = false
            finished.finish_ts = finished.finish_ts or os.time()
            M._pushDownloadHistory(finished)
        end
        M.is_downloading = false
    end
    M.persist_download_task()
end

function M.updateDownloadProgress(cur, total, title)
    if M.download_task then
        -- 只在进度变化超过 1% 时才更新，减少内存赋值和潜在的 UI 刷新
        local last_pct = M.download_task._last_reported_pct or -1
        local new_pct = total > 0 and math.floor((cur / total) * 100) or 0
        if new_pct ~= last_pct or (title and M.download_task.title ~= title) then
            M.download_task.current = cur
            M.download_task.total = total
            M.download_task._last_reported_pct = new_pct
            if title ~= nil then
                M.download_task.title = title
            end
        end
        -- 进度频繁变更时延迟持久化（避免写爆磁盘），此处仅内存态保留
    end
end

function M.clearDownloadTask()
    local now = os.clock()
    -- 防抖：如果任务已经是 nil 或 is_downloading 已经是 false，跳过
    if M.download_task == nil and not M.is_downloading then
        return  -- 已经清理过了
    end

    local task = M.download_task
    if task and M.is_downloading then
        -- 已调用 clearDownloadTask：若任务存在且未标记 finished，视为取消/中断
        task.is_downloading = false
        task.finish_ts = task.finish_ts or os.time()
        if not task.success then
            task.cancelled = true
        end
        M._pushDownloadHistory(task)
    end
    M.download_task = nil
    M.is_downloading = false
    -- 防抖：100ms 内不再重复写入
    _task_set_cooldown_until = now + 0.1
    M.persist_download_task()
end

function M.getDownloadTask()
    return M.download_task
end

-- ============================================================
-- 预下载独立标志（不阻塞，与手动下载冲突时跳过）
-- ============================================================
function M.setPreDownloading(val)
    M.pre_downloading = val and true or false
end

function M.isPreDownloading()
    return M.pre_downloading
end

function M.markPreDownloadTriggered()
    M.pre_download_triggered = true
end

function M.isPreDownloadTriggered()
    return M.pre_download_triggered
end

function M.resetPreDownloadTriggered()
    M.pre_download_triggered = false
end

-- ============================================================
-- 下载历史（最多10条）
-- ============================================================
function M._pushDownloadHistory(task)
    if not task then return end
    -- 避免重复推入（同一 fmd 短时间内重复）
    local fmd = tostring(task.file_md5 or task.fmd or "")
    for i = #M.download_history, 1, -1 do
        local h = M.download_history[i]
        if tostring(h.file_md5 or h.fmd or "") == fmd then
            -- 已存在，直接更新这条为最新状态
            for k, v in pairs(task) do
                if type(v) ~= "function" then
                    h[k] = v
                end
            end
            return
        end
    end
    table.insert(M.download_history, 1, task)
    while #M.download_history > DOWNLOAD_HISTORY_MAX do
        table.remove(M.download_history, #M.download_history)
    end
    M.persist_download_history()
end

function M.getDownloadHistory()
    return M.download_history or {}
end

function M.clearDownloadHistory()
    M.download_history = {}
    M.persist_download_history()
end

-- ============================================================
-- 云端进度上传任务
-- ============================================================
function M.setProgressUploadTask(t)
    M.progress_upload_task = t
end

function M.clearProgressUploadTask()
    M.progress_upload_task = nil
end

function M.getProgressUploadTask()
    return M.progress_upload_task
end

-- ============================================================
-- 最近阅读时间
-- ============================================================
function M.getLastReadTime(fmd)
    if not fmd then return nil end
    return M.last_read_time[fmd]
end

function M.touchLastReadTime(fmd)
    if not fmd then return end
    M.last_read_time[fmd] = os.time()
end

-- ============================================================
-- 目录缓存（系列卷列表缓存，24h TTL）
-- ============================================================
function M.setDirectoryCache(series_id, vols)
    if not series_id then return end
    M.directory_cache[tostring(series_id)] = {
        ts = os.time(),
        vols = vols,
    }
end

function M.getDirectoryCache(series_id)
    if not series_id then return nil end
    local cache = M.directory_cache[tostring(series_id)]
    if not cache then return nil end
    if os.time() - cache.ts > M.DIRECTORY_CACHE_TTL then
        M.directory_cache[tostring(series_id)] = nil
        return nil
    end
    return cache.vols
end

function M.invalidateDirectoryCache(series_id)
    if series_id then
        M.directory_cache[tostring(series_id)] = nil
    else
        M.directory_cache = {}
    end
end

-- ============================================================
-- 章节下载索引缓存（24h TTL，避免每次都查文件系统）
-- ============================================================
function M.setDownloadedChapters(series_id, downloaded_map)
    if not series_id then return end
    M.chapter_index_cache[tostring(series_id)] = {
        ts = os.time(),
        downloaded = downloaded_map or {},
    }
end

function M.getDownloadedChapters(series_id)
    if not series_id then return nil end
    local cache = M.chapter_index_cache[tostring(series_id)]
    if not cache then return nil end
    if os.time() - cache.ts > M.CHAPTER_INDEX_CACHE_TTL then
        M.chapter_index_cache[tostring(series_id)] = nil
        return nil
    end
    return cache.downloaded
end

function M.invalidateDownloadedChapters(series_id)
    if series_id then
        M.chapter_index_cache[tostring(series_id)] = nil
    else
        M.chapter_index_cache = {}
    end
end

-- ============================================================
-- 跨 Plugin 实例共享：KOReader 在 FileManager 和 ReaderUI 中
-- 分别 new Plugin 实例，这俩 instance 的 self.xxx 彼此独立，
-- 所以 bookshelf/settings/client/download/shelf_view 必须集中存在 state 里，
-- ReaderUI 模式 init 时复用（不重复 new）。
-- ============================================================
-- 共享模块句柄：由 FileManager 模式的 Plugin:init 首次写入，ReaderUI 实例只读
M._shared = {
    initialized = false,
    settings = nil,
    client = nil,
    auth = nil,
    bookshelf = nil,
    download = nil,
    reader = nil,
    shelf_view = nil,     -- 这里放的是 ShelfView 模块表（不是某个 menu 句柄），供两个 instance require
    ShelfView = nil,      -- 兼容 fanqie 风格命名
}

function M.bindSharedModules(t)
    if not t then return end
    for k, v in pairs(t) do
        M._shared[k] = v
    end
    M._shared.initialized = true
end

function M.getShared()
    return M._shared
end

function M.isSharedInitialized()
    return M._shared.initialized == true
end

-- ============================================================
-- 上次打开的卷：用于 onShowToc（阅读界面点目录回到对应系列卷目录）
-- 存 state 而非 Plugin instance，因为 ReaderUI/FileManager 实例分离
-- ============================================================
M._last_open_vol = nil
M._last_open_series_id = nil

function M.setLastOpenVol(vol, series_id)
    M._last_open_vol = vol
    M._last_open_series_id = series_id
end

function M.getLastOpenVol()
    return M._last_open_vol
end

function M.getLastOpenSeriesId()
    return M._last_open_series_id
end

return M
