local lfs = require("libs/libkoreader-lfs")
local H = require("koobone.helper")
local Log = require("koobone.logger")
local Async = require("koobone.async")
local _state = require("koobone.state")
local HttpDL = require("koobone.http_downloader")
local Queue = require("koobone.queue")
local ok_DLProgress, DownloadProgress = pcall(require, "koobone.download_progress")
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")

local Download = {}
Download.__index = Download

function Download:new(settings, client, bookshelf)
    local obj = {
        settings = settings,
        client = client,
        bookshelf = bookshelf,
        EPUB_CACHE_DIR = H.get_epub_dir(),
        MAX_CACHE_BYTES = (settings:get_cache_max_mb() or 1024) * 1024 * 1024,
        MAX_AGE_SECONDS = 48 * 3600,
    }
    H.make_dir(obj.EPUB_CACHE_DIR)
    local q = Queue.create()
    obj._queue_state = q
    obj._active_downloads = q._active_downloads
    obj._download_queue = q._download_queue
    return setmetatable(obj, self)
end


function Download:_epub_path(vol, fmd, file_md5)
    -- 兼容旧调用形式: _epub_path(fmd, file_md5)
    if type(vol) ~= "table" then
        file_md5 = fmd
        fmd = vol
        vol = nil
    end
    -- 新命名路径（含系列子目录）
    local subdir = H.epub_subdir_for_vol(vol)
    local full_dir = self.EPUB_CACHE_DIR
    if subdir and subdir ~= "" then
        full_dir = H.join_path(self.EPUB_CACHE_DIR, subdir)
    end
    local name = H.epub_filename_for_vol(vol, fmd, file_md5)
    return H.join_path(full_dir, name)
end

--- 旧命名路径（纯 file_md5，在 epub_dir 根目录），仅用于兼容查找/删除
function Download:_epub_legacy_path(fmd, file_md5)
    local name = H.epub_legacy_filename(fmd, file_md5)
    return H.join_path(self.EPUB_CACHE_DIR, name)
end

--- 解析已存在的 EPUB 路径：优先新命名（按系列分子目录），其次旧命名（根目录，命中时自动迁移）
-- 若都不存在，确保新路径父目录存在，返回新路径供调用方写入下载文件
function Download:_resolve_epub_path(vol, fmd, file_md5)
    return H.resolve_epub_path(self.EPUB_CACHE_DIR, vol, fmd, file_md5)
end

--- 当前生效的缓存上限（字节）。
-- 每次现读 settings 而不是用构造时的 MAX_CACHE_BYTES 快照：Download 实例被放进
-- State._shared，整个进程生命周期只 new 一次 —— 用户在菜单里改「缓存上限」后
-- 若不现读，新的上限要等到重启 KOReader 才生效。
function Download:_cache_max_bytes()
    local max_mb = nil
    if self.settings and self.settings.get_cache_max_mb then
        max_mb = self.settings:get_cache_max_mb()
    end
    if max_mb and max_mb > 0 then
        return max_mb * 1024 * 1024
    end
    return self.MAX_CACHE_BYTES
end

--- 触发一次 LRU 缓存清理（带开关 + 频率保护）。
--
-- 【为什么需要这层包装】`_lru_cleanup` 此前是全仓库零调用的死代码 —— README 写着
-- 「EPUB 缓存与 LRU 自动清理」，实际 EPUB_CACHE_DIR 只会无限增长。现在有两条调用链：
--   ① 下载成功后的 on_success（缓存只在下新书时增长，最自然的回收时机）；
--   ② 插件启动后延迟一次（回收「过期但没再下载过」的老文件）。
--
-- ⚠️ 重入保护用**时间戳**而不是布尔标志：清理要遍历目录并递归统计每个系列子目录的
-- 大小，是 UI 线程上的同步扫盘；批量下载 20 卷会触发 20 次 on_success，必须用频率
-- 门限把它们收敛成一次。而布尔标志一旦在某条异常路径上没被复位，清理就**永久失效** ——
-- 这种静默失效比多扫一遍严重得多（同 shelf_view/reading 的既有教训）。
--
-- @param min_interval number|nil 距上次清理不足该秒数则跳过（默认 3600 = 1 小时）
-- @return boolean 本次是否真的执行了清理
function Download:maybe_lru_cleanup(min_interval)
    if self.settings and self.settings.is_cache_lru_enabled
        and not self.settings:is_cache_lru_enabled() then
        return false
    end
    min_interval = min_interval or 3600
    local now = os.time()
    if self._lru_cleanup_at and (now - self._lru_cleanup_at) < min_interval then
        return false
    end
    self._lru_cleanup_at = now
    local ok, err = pcall(function() self:_lru_cleanup() end)
    if not ok then
        Log.warn("[KooboneCache] LRU 清理异常: " .. tostring(err))
    end
    return true
end

function Download:_lru_cleanup()
    H.lru_cleanup(self.EPUB_CACHE_DIR, {
        max_age = self.MAX_AGE_SECONDS,
        max_bytes = self:_cache_max_bytes(),
    })
end

--- 带进度回调的 HTTP 下载
function Download:_do_http_download_with_progress(url, save_tmp_path, expected_size, verify_ssl, fmd, progress_callback, cancel_check)
    -- api_key 直传鉴权：图片/文件下载无需 cookie
    return HttpDL.do_http_download_with_progress(url, save_tmp_path, expected_size, verify_ssl, "", progress_callback, cancel_check)
end

--- 带进度回调的 EPUB 下载方法
-- @param vol 卷信息
-- @param file_url 下载链接
-- @param expected_size 预期文件大小
-- @param file_md5 文件 MD5
-- @param progress_callback 进度回调 function(current, total, stage, message)
-- @param cancel_check 取消检查回调 function() -> boolean
-- @return epub_path, err
function Download:_download_epub_file_with_progress(vol, file_url, expected_size, file_md5, progress_callback, cancel_check)
    local fmd = tostring(vol.file_md5 or vol.fmd or "unknown")
    H.make_dir(self.EPUB_CACHE_DIR)
    -- 解析已存在路径（自动迁移旧命名到新命名）
    local epub_path = self:_resolve_epub_path(vol, fmd, file_md5)
    expected_size = tonumber(expected_size) or 0

    -- 优化: 不再单独发送 HEAD 请求获取文件大小
    -- 如果 API 调用方已提供 expected_size 则直接使用
    -- 否则由 http_downloader 在 GET 响应中自动从 Content-Length 提取
    if expected_size == 0 then
        Log.info("[KooboneDownload] expected_size 未知，将从 GET 响应头自动获取")
    end

    -- 检查缓存
    if H.file_exists(epub_path) then
        local cur_size = H.file_size(epub_path)
        if expected_size and expected_size > 0 then
            local ratio = cur_size / expected_size
            if ratio >= 0.95 and ratio <= 1.05 then
                Log.info("[KooboneDownload] 命中缓存 fmd=" .. fmd .. " size=" .. tostring(cur_size))
                if progress_callback then
                    progress_callback(cur_size, expected_size, "done", "命中缓存")
                end
                return epub_path, nil
            end
        else
            if progress_callback then
                progress_callback(cur_size, expected_size, "done", "命中缓存")
            end
            return epub_path, nil
        end
    end

    local tmp_path = epub_path .. ".downloading"
    -- 优化: 不再无条件删除 tmp 文件，保留用于断点续传

    -- 检查取消
    if cancel_check and cancel_check() then
        if progress_callback then
            progress_callback(0, expected_size, "cancelled", "下载已取消")
        end
        return nil, "下载已取消"
    end

    local is_https = file_url:find("^https://") == 1
    local http_url = nil
    if is_https then
        http_url = "http://" .. file_url:sub(9)
    end

    local strategies = {
        { name = "HTTPS+NoVerify", url = file_url, verify = false },
    }
    if is_https and http_url then
        table.insert(strategies, { name = "HTTP+Fallback", url = http_url, verify = true })
    end

    local last_err = nil
    local strat_names = {}
    for _, s in ipairs(strategies) do table.insert(strat_names, s.name) end
    Log.info("[KooboneDownload] 策略列表: " .. table.concat(strat_names, ", ") .. " fmd=" .. fmd)
    local prev_strat_url = nil
    for si, strat in ipairs(strategies) do
        Log.info("[KooboneDownload] 使用策略 " .. strat.name .. " (第" .. si .. "/" .. #strategies .. "个) verify=" .. tostring(strat.verify))
        -- 优化: 切换策略(URL变化)时删除 tmp 文件重新开始，同一策略重试则保留断点
        if prev_strat_url and prev_strat_url ~= strat.url then
            if H.file_exists(tmp_path) then
                Log.info("[KooboneDownload] 切换策略(URL变化)，删除旧断点文件重新下载")
                pcall(os.remove, tmp_path)
            end
        end
        prev_strat_url = strat.url

        -- 检查取消
        if cancel_check and cancel_check() then
            Log.info("[KooboneDownload] 下载被取消，跳过后续策略（保留断点文件）")
            if progress_callback then
                progress_callback(0, expected_size, "cancelled", "下载已取消")
            end
            return nil, "下载已取消"
        end

        for attempt = 1, 3 do
            -- 再次检查取消
            if cancel_check and cancel_check() then
                Log.info("[KooboneDownload] 下载被取消(尝试" .. attempt .. ")（保留断点文件）")
                if progress_callback then
                    progress_callback(0, expected_size, "cancelled", "下载已取消")
                end
                return nil, "下载已取消"
            end

            -- 优化: 同一策略重试时不删除 tmp 文件，利用断点续传
            if progress_callback then
                local exist_bytes = H.file_size(tmp_path)
                if exist_bytes > 0 then
                    progress_callback(exist_bytes, expected_size, "resume", "断点续传尝试 " .. attempt .. "/3")
                else
                    progress_callback(0, expected_size, "downloading", "下载策略:" .. strat.name .. " 尝试" .. attempt .. "/3")
                end
            end

            -- 带进度的 HTTP 下载（使用 pcall 防止异常中断策略循环）
            local ok_call, size, err = pcall(function()
                return self:_do_http_download_with_progress(strat.url, tmp_path, expected_size, strat.verify, fmd, progress_callback, cancel_check)
            end)

            if not ok_call then
                last_err = tostring(size or "unknown error")
                Log.warn("[KooboneDownload] 策略 " .. strat.name .. " 尝试" .. attempt
                    .. "/3 异常 fmd=" .. fmd .. " err=" .. last_err)
            elseif size and not err then
                local rename_ok, rename_err = os.rename(tmp_path, epub_path)
                if not rename_ok then
                    pcall(os.remove, tmp_path)
                    last_err = "临时文件重命名失败: " .. tostring(rename_err)
                    Log.warn("[KooboneDownload] 文件重命名失败: " .. last_err)
                else
                    Log.info("[KooboneDownload] 下载完成 strategy=" .. strat.name
                        .. " fmd=" .. fmd .. " size=" .. tostring(size))
                    if progress_callback then
                        progress_callback(size, expected_size, "done", "下载完成")
                    end
                    return epub_path, nil
                end
            else
                last_err = tostring(err or "unknown")
                Log.warn("[KooboneDownload] 策略 " .. strat.name .. " 尝试" .. attempt
                    .. "/3 失败 fmd=" .. fmd .. " err=" .. last_err)
            end
        end
        Log.info("[KooboneDownload] 策略 " .. strat.name .. " 所有尝试已失败，继续下一策略")
    end

    Log.warn("[KooboneDownload] 所有策略均已失败 fmd=" .. fmd .. " last_err=" .. tostring(last_err))
    if H.file_exists(tmp_path) then
        pcall(os.remove, tmp_path)
    end
    return nil, "下载 EPUB 失败: " .. tostring(last_err)
end

--- 删除卷缓存的 EPUB 文件
-- 接受三种调用形式:
--   delete_vol_cache(vol, fmd, file_md5)  推荐，会同时删除新+旧命名
--   delete_vol_cache(fmd, file_md5)       兼容旧调用
-- 兼容旧命名残留文件，确保切换命名规则后旧文件也能被清理
function Download:delete_vol_cache(vol_or_fmd, fmd_arg, file_md5_arg)
    local vol, fmd, file_md5
    if type(vol_or_fmd) == "table" then
        vol = vol_or_fmd
        fmd = tostring(fmd_arg or vol.file_md5 or vol.fmd or "")
        file_md5 = file_md5_arg or vol.file_md5 or fmd
    else
        -- 旧调用形式: delete_vol_cache(fmd, file_md5)
        fmd = tostring(vol_or_fmd or "")
        file_md5 = fmd_arg or fmd
        vol = nil
    end
    if fmd == "" and (not file_md5 or file_md5 == "") then
        return false
    end
    local ok, err = pcall(function()
        -- 新命名路径
        local new_path = self:_epub_path(vol, fmd, file_md5)
        if H.file_exists(new_path) then
            Log.info("[KooboneDownload] 删除卷缓存 EPUB(新命名):", new_path)
            os.remove(new_path)
        end
        -- 旧命名路径（兼容残留）
        local legacy_path = self:_epub_legacy_path(fmd, file_md5)
        if legacy_path ~= new_path and H.file_exists(legacy_path) then
            Log.info("[KooboneDownload] 删除卷缓存 EPUB(旧命名):", legacy_path)
            os.remove(legacy_path)
        end
    end)
    if not ok then
        Log.error("[KooboneDownload] delete_vol_cache 失败:", tostring(err))
        return false
    end
    return true
end

-- ============ 统一下载队列管理 ============

-- 检查卷是否正在下载
function Download:is_downloading(fmd)
    return Queue.is_downloading(self._queue_state, fmd)
end

-- 检查卷是否在 pending 队列（已排队、尚未开始下载）
function Download:is_enqueued(fmd)
    return Queue.is_enqueued(self._queue_state, fmd)
end

-- 检查卷是否已下载
function Download:is_downloaded(vol)
    if not vol then return false end
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return false end
    local epub_path = self:_resolve_epub_path(vol, fmd, vol.file_md5)
    if H.file_exists(epub_path) then
        if self.bookshelf then
            pcall(function()
                local cached_vol = self.bookshelf:get_vol_by_fmd(fmd)
                if cached_vol then cached_vol._local_downloaded = true end
            end)
        end
        return true
    end
    return false
end


-- 添加到下载队列
function Download:enqueue(vol, opts)
    local callbacks = self:_queue_callbacks(vol)
    return Queue.enqueue(self._queue_state, vol, opts, callbacks)
end

-- 批量添加到下载队列
function Download:enqueue_batch(vols, opts)
    local first_vol = vols and vols[1]
    local callbacks = self:_queue_callbacks(first_vol)
    return Queue.enqueue_batch(self._queue_state, vols, opts, callbacks)
end

function Download:_queue_callbacks(vol)
    -- 防止重复 clearDownloadTask 的守卫：确保同一个任务只清理一次
    local _task_cleared = false

    local function download_fn(v, fmd)
        local file_url = self:_get_file_url(v, fmd)
        if not file_url then
            return nil, "无下载链接"
        end
        local expected_size = self:_get_expected_size(v)
        local file_md5 = self:_get_file_md5(v, fmd)
        -- 1) 构造 IPC 路径：子进程通过 progress_file 把实时字节进度写回，
        --    父进程 poll_progress_once 读取后更新 UI（Async.run fork 隔离下必须这样）
        local ipc_opts = self:ipc_paths(fmd)

        -- 2) 同时写 _state.updateDownloadProgress（同步降级模式 / 单进度测试下有用）
        local _last_progress_report = 0
        local function on_progress(current, total, stage, message)
            local now = os.clock()
            -- 进度节流：每 0.2 秒最多更新一次 state，减少频繁写盘触发的局刷
            if now - _last_progress_report < 0.2 then return end
            _last_progress_report = now
            if _state and _state.updateDownloadProgress then
                local title_str = nil
                if message and message ~= "" then
                    title_str = message
                end
                _state.updateDownloadProgress(current, total, title_str)
            end
        end
        -- 3) 走带 IPC+progress_callback 的下载流程
        local epub_path, err = self:_download_epub_file_with_progress_ipc(v, file_url, expected_size, file_md5, on_progress, ipc_opts)
        return epub_path, err
    end

    -- 统一清理函数：只执行一次
    local function _cleanup_task(v, success, err)
        if _task_cleared then return end
        _task_cleared = true
        pcall(function()
            local cur_task = _state.getDownloadTask and _state.getDownloadTask()
            if cur_task then
                local tfmd = tostring(cur_task.file_md5 or cur_task.fmd or "")
                local vfmd = tostring(v.file_md5 or v.fmd or "")
                if tfmd == "" or tfmd == vfmd then
                    cur_task.success = success
                    cur_task.error_msg = success and nil or tostring(err or "下载失败")
                end
            end
        end)
        pcall(function()
            if _state.clearDownloadTask then
                _state.clearDownloadTask()
            elseif _state.setDownloadTask then
                _state.setDownloadTask(nil)
            end
        end)
    end

    return {
        is_downloaded = function(v) return self:is_downloaded(v) end,
        download = download_fn,
        async_run = Async.run,
        on_success = function(v, epub_path)
            if self.bookshelf then
                pcall(function()
                    local fmd = tostring(v.file_md5 or v.fmd or "")
                    local cached_vol = self.bookshelf:get_vol_by_fmd(fmd)
                    if cached_vol then
                        cached_vol._local_downloaded = true
                    end
                    self.bookshelf:_save_shelf_cache()
                end)
            end
            -- 下载成功后顺手清理一次缓存：EPUB 缓存只在下新书时增长，这是最自然的
            -- 回收时机。延后 2s 到下一帧执行 —— 清理要在 UI 线程同步遍历缓存目录并
            -- 递归统计每个系列子目录的大小，直接放在回调里会卡住下载队列的下一个任务。
            -- maybe_lru_cleanup 自带 1 小时频率门限，批量下载不会反复扫盘。
            if ok_UIManager and UIManager and self.maybe_lru_cleanup then
                local dl_ref = self
                UIManager:scheduleIn(2, function()
                    pcall(function() dl_ref:maybe_lru_cleanup() end)
                end)
            end
            _cleanup_task(v, true, nil)
        end,
        on_fail = function(v, err)
            _cleanup_task(v, false, err)
        end,
    }
end

-- 带 IPC 进度通道 + progress_callback 的 EPUB 下载封装
-- 比 _download_epub_file_with_progress 多做两件事：
--   a) 传入 ipc_opts，让 _download_epub_file_with_progress 能写 HttpDL.ipc_write_progress
--   b) 开始前清理旧 IPC 文件，结束后清理，避免残留
function Download:_download_epub_file_with_progress_ipc(vol, file_url, expected_size, file_md5, progress_callback, ipc_opts)
    ipc_opts = ipc_opts or {}
    -- 清理旧 IPC 残留，避免进度回滚
    if HttpDL.ipc_cleanup then
        pcall(function() HttpDL.ipc_cleanup(ipc_opts.progress_file, ipc_opts.cancel_file) end)
    end

    local update_progress
    if progress_callback then
        update_progress = progress_callback
    else
        update_progress = function() end
    end

    -- 直接复用 _download_epub_file_with_progress 核心：
    --   传 progress_callback + ipc_opts。_download_epub_file_with_progress 里 update_progress
    --   会 if progress_file then HttpDL.ipc_write_progress(...)，正好写子进程→父进程通道
    -- 但现在的函数签名是 (vol, file_url, expected_size, file_md5, progress_callback, cancel_check)，
    -- 没有 ipc_opts 参数。我们需要临时绑定进度回调内部写 IPC。
    -- 做法：在 progress_callback 外层再包一层 IPC 写。
    local function wrapped_progress(current, total, stage, message)
        update_progress(current, total, stage, message)
        if ipc_opts.progress_file and HttpDL.ipc_write_progress then
            pcall(function()
                HttpDL.ipc_write_progress(ipc_opts.progress_file, {
                    current = current,
                    total = total,
                    stage = stage,
                    message = message,
                })
            end)
        end
    end
    local cancel_check
    if ipc_opts.cancel_file and HttpDL.ipc_check_cancel then
        cancel_check = function()
            return HttpDL.ipc_check_cancel(ipc_opts.cancel_file)
        end
    end
    return self:_download_epub_file_with_progress(vol, file_url, expected_size, file_md5, wrapped_progress, cancel_check)
end

-- 从队列中移除
function Download:remove_from_queue(fmd)
    return Queue.remove_from_queue(self._queue_state, fmd)
end


-- ===== 队列内部辅助：解析卷下载信息 =====

function Download:_get_file_url(vol, fmd)
    local file_url = vol.file_url
    -- 关键修复：file_url 带 sign/time 参数，可能很快过期（koobone 下载链接通常有效期很短）
    -- 策略：如果 vol 来自缓存，先检查 URL 是否新鲜（通过 time 参数判断）
    local needs_refresh = false
    if file_url and file_url ~= "" then
        -- 检查 URL 中的 time 参数是否已过期
        local time_param = file_url:match("time=(%d+)")
        if time_param then
            local url_time = tonumber(time_param) or 0
            local now = os.time()
            -- 如果 URL 时间戳与当前时间差超过 3600 秒（1小时），认为可能过期
            if now > url_time and (now - url_time) > 3600 then
                Log.debug("[KooboneDownload] file_url 可能已过期 (time=" .. time_param .. ", now=" .. now .. ")，刷新获取")
                needs_refresh = true
            end
        end
    end

    if not needs_refresh and file_url and file_url ~= "" then
        -- 如果 URL 看起来还新鲜，先尝试用它
        return file_url
    end

    -- 尝试从 bookshelf 缓存获取
    if self.bookshelf then
        local local_vol = self.bookshelf:get_vol_by_fmd(fmd)
        if local_vol and local_vol.file_url and local_vol.file_url ~= "" then
            local local_url = local_vol.file_url
            -- 同样检查本地缓存 URL 是否过期
            local local_time = local_url:match("time=(%d+)")
            if local_time then
                local local_url_time = tonumber(local_time) or 0
                local now = os.time()
                if now > local_url_time and (now - local_url_time) > 3600 then
                    Log.debug("[KooboneDownload] 缓存 file_url 也已过期，调用 API 刷新")
                    -- 跳过缓存，直接走 API
                else
                    return local_url
                end
            else
                -- 没有 time 参数，保守使用
                return local_url
            end
        end
    end

    -- 关键修复：总是尝试从 API 获取最新的 file_url（绕过过期的缓存）
    if self.client then
        Log.debug("[KooboneDownload] _get_file_url 调用 API 获取新鲜 URL fmd=" .. tostring(fmd))
        local v = self.client:query_vol_info(fmd)
        if v and v.file_url and v.file_url ~= "" then
            -- 更新缓存中的数据（不仅是 file_url，同步所有关键字段）
            if self.bookshelf then
                local cached_vol = self.bookshelf:get_vol_by_fmd(fmd)
                if cached_vol then
                    -- 同步下载相关字段，确保缓存新鲜
                    cached_vol.file_url = v.file_url
                    if v.file_size then cached_vol.file_size = v.file_size end
                    if v.file_type then cached_vol.file_type = v.file_type end
                    if v.time_update then cached_vol.time_update = v.time_update end
                    -- 同步其他可能变化的字段
                    for _, key in ipairs({"status", "vol_language", "time_add", "vol_publisher", "store_area", "file_from"}) do
                        if v[key] ~= nil then
                            cached_vol[key] = v[key]
                        end
                    end
                    Log.debug("[KooboneDownload] 已同步缓存 vol 数据 fmd=" .. tostring(fmd))
                end
            end
            return v.file_url
        end
    end

    -- 最后兜底：返回原来的 file_url（可能过期，但总比没有好）
    if file_url and file_url ~= "" then
        return file_url
    end
    return nil
end

function Download:_get_expected_size(vol)
    local size = tonumber(vol.file_size) or 0
    if size > 0 then return size end
    if self.bookshelf then
        local local_vol = self.bookshelf:get_vol_by_fmd(tostring(vol.file_md5 or vol.fmd or ""))
        if local_vol then
            local s = tonumber(local_vol.file_size) or 0
            if s > 0 then return s end
        end
    end
    return 0
end

function Download:_get_file_md5(vol, fmd)
    if vol.file_md5 then return vol.file_md5 end
    return fmd
end

-- ===== 公开 IPC 方法（供父进程调用）=====

-- 生成下载进度的 IPC 文件路径
function Download:ipc_paths(fmd)
    local base = self.EPUB_CACHE_DIR .. "/_ipc_" .. tostring(fmd or "unknown")
    return {
        progress_file = base .. "_progress.json",
        cancel_file = base .. "_cancel.flag",
    }
end

-- 父进程读取子进程写入的进度
function Download:ipc_read_progress(progress_file)
    return HttpDL.ipc_read_progress(progress_file)
end

-- 父进程发送取消信号
-- @return boolean 是否确认写入成功（见 HttpDL.ipc_write_cancel）
function Download:ipc_send_cancel(cancel_file)
    return HttpDL.ipc_write_cancel(cancel_file)
end

-- 清理 IPC 文件
function Download:ipc_cleanup(paths)
    if not paths then return end
    HttpDL.ipc_cleanup(paths.progress_file, paths.cancel_file)
end

-- ===== 统一取消入口 =====
-- Download 是下载状态（_download_queue / _active_downloads）的唯一持有者，
-- 取消也只从这一个入口走，信号源统一为 IPC cancel.flag：
--   · 还在 pending 队列（未开始下载）→ 直接出队；
--   · 已在下载中 → 写 IPC cancel.flag，子进程在下载循环里检查后中止并保留断点。
-- shelf_view 的进度弹窗"取消下载"此前调用的是并不存在的方法 `download:cancel(fmd)`，
-- 被 pcall 吞掉 → 取消了 UI 轮询但子进程仍在跑。
-- @return boolean 是否命中（出队成功或已发出取消信号）
function Download:cancel(fmd)
    if not fmd or fmd == "" then return false end
    fmd = tostring(fmd)

    local dequeued = self:remove_from_queue(fmd)

    local signalled = false
    if self._active_downloads[fmd] then
        local paths = self:ipc_paths(fmd)
        -- 只有信号**确实写出去**了才算取消已发出：此前无条件置 signalled = true，
        -- 于是「取消信号写失败」时调用方仍收到「已取消」，而子进程照跑到底。
        local sent = self:ipc_send_cancel(paths.cancel_file)
        if sent then
            signalled = true
            Log.info("[KooboneDownload] 已发送取消信号 fmd=" .. fmd)
        else
            Log.warn("[KooboneDownload] 取消信号写入失败，子进程可能继续下载 fmd=" .. fmd)
        end
    end

    if not dequeued and not signalled then
        Log.info("[KooboneDownload] 取消未命中（不在队列也不在下载中）fmd=" .. fmd)
    end
    return dequeued or signalled
end

return Download
