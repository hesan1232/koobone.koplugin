local M = {
    current_comic = nil,
    current_page = 0,
    shelf_vols_cache = nil,
    shelf_cache_ttl = 30,
    current_shelf_sort = "uptime",
    download_task = nil,
    progress_upload_task = nil,
    last_read_time = {},
}

function M.getCurrentComic()
    return M.current_comic
end

function M.setCurrentComic(c)
    M.current_comic = c
end

function M.getCurrentPage()
    return M.current_page
end

function M.setCurrentPage(p)
    M.current_page = p or 0
end

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

function M.getShelfSort()
    return M.current_shelf_sort
end

function M.setShelfSort(sort_key)
    if sort_key == "uptime" or sort_key == "vol_name" then
        M.current_shelf_sort = sort_key
    end
end

function M.setDownloadTask(t)
    M.download_task = t
end

function M.updateDownloadProgress(cur, total, title)
    if M.download_task then
        M.download_task.current = cur
        M.download_task.total = total
        if title ~= nil then
            M.download_task.title = title
        end
    end
end

function M.clearDownloadTask()
    M.download_task = nil
end

function M.getDownloadTask()
    return M.download_task
end

function M.setProgressUploadTask(t)
    M.progress_upload_task = t
end

function M.clearProgressUploadTask()
    M.progress_upload_task = nil
end

function M.getProgressUploadTask()
    return M.progress_upload_task
end

function M.getLastReadTime(fmd)
    if not fmd then return nil end
    return M.last_read_time[fmd]
end

function M.touchLastReadTime(fmd)
    if not fmd then return end
    M.last_read_time[fmd] = os.time()
end

return M
