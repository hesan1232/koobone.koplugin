local H = require("koobone.helper")
local Log = require("koobone.logger")
local _state = require("koobone.state")
local Async = require("koobone.async")

local ok_UIManager, UIManager = pcall(require, "ui/uimanager")

local Progress = {}
Progress.__index = Progress

function Progress:new(settings, client, bookshelf)
    local obj = {
        settings = settings,
        client = client,
        bookshelf = bookshelf,
        _current_fmd = nil,
        _current_page = 0,
        _current_total = 0,
        _last_upload_page = -1,
        _last_upload_ts = 0,
        _timer_handle = nil,
        _destroyed = false,
        _ending = false,
        -- 【会话令牌】每次 start_session 自增。异步回调执行时比对，不一致即放弃 ——
        -- 防止「换书后旧回调仍把结果写进当前会话」。作用等同 reading 的 Context.generation。
        _session_gen = 0,
        -- 对外只读视图：reader / shelf_view 通过 progress.last_page / progress.total_pages
        -- 读取当前进度。由 _sync_public() 与 _current_page/_current_total 保持同步。
        last_page = 0,
        total_pages = 0,
    }
    return setmetatable(obj, self)
end

--- 同步对外只读字段。所有对 _current_page / _current_total 的写入都必须跟一次本调用，
--- 否则 reader（周期性同步、关闭时落盘）读到的是过期值。
function Progress:_sync_public()
    self.last_page = self._current_page
    self.total_pages = self._current_total
end

function Progress:start_session(fmd, initial_page_or_nil, total_pages, on_progress_pulled)
    if self._destroyed then return false end

    -- 【会话令牌】（见 _session_gen 的说明）
    self._session_gen = (self._session_gen or 0) + 1
    local session_gen = self._session_gen

    self._current_fmd = fmd
    self._current_page = tonumber(initial_page_or_nil) or 0
    self._current_total = tonumber(total_pages) or 0
    self:_sync_public()

    if self.settings:is_auto_pull_progress() then
        local local_page = 0
        if self.bookshelf then
            local vol = self.bookshelf:get_vol_by_fmd(fmd)
            if vol then
                local_page = tonumber(vol.last_readpage) or 0
            end
        end

        Log.debug("[Progress] start_session: fmd=" .. tostring(fmd)
            .. ", local_page=" .. tostring(local_page)
            .. ", total=" .. tostring(self._current_total))

        Async.run(function()
            if not self.client then return nil end
            return self.client:query_vol_info(fmd)
        end, function(ok, vol_info, err)
            -- 【身份校验】会话已销毁 / 已换书（fmd 变）/ 已换会话（gen 变）→ 结果作废
            if self._destroyed or self._session_gen ~= session_gen or self._current_fmd ~= fmd then
                return
            end
            if ok and vol_info then
                local cloud_page = tonumber(vol_info.last_readpage) or 0
                Log.debug("[Progress] 云端进度返回: cloud_page=" .. tostring(cloud_page)
                    .. ", local_page=" .. tostring(local_page))
                if cloud_page > local_page and on_progress_pulled then
                    on_progress_pulled(cloud_page, self._current_total, vol_info)
                end
            else
                Log.warn("[Progress] 拉取云端进度失败:", tostring(err or "unknown"))
            end
        end, { timeout = 30, tag = "progress" })
    end

    local interval = tonumber(self.settings:get_progress_upload_interval()) or 60
    if interval > 0 and ok_UIManager and UIManager then
        Log.debug("[Progress] 启动定时上传定时器, interval=" .. tostring(interval) .. "s")
        local timer_cb
        timer_cb = function()
            if self._destroyed then return end
            if self._current_fmd then
                self:_upload_now(false)
            end
            self._timer_handle = UIManager:scheduleIn(interval, timer_cb)
        end
        self._timer_handle = UIManager:scheduleIn(interval, timer_cb)
    end

    return true
end


--- 仅更新本地进度，**不触发上传**。
-- 供 Reader 的周期性同步（每 30s）调用：它只需把当前页码喂给 session，
-- 真正的上传由 start_session 里那个 interval 定时器统一负责，避免两条路径各自上传。
-- reader.lua 此前调用的是并不存在的 `update_local_progress`，导致页码永远进不了 session，
-- 定时上传的永远是初始页码 → 进度同步形同虚设。
function Progress:update_local_progress(page_idx, total_pages_opt)
    if self._destroyed or not self._current_fmd then return end

    self._current_page = tonumber(page_idx) or self._current_page
    if total_pages_opt then
        self._current_total = tonumber(total_pages_opt) or self._current_total
    end
    self:_sync_public()

    _state.setCurrentPage(self._current_page)
    if self.bookshelf then
        self.bookshelf:touch_vol_read_time(self._current_fmd)
    end
end

function Progress:_upload_now(force, on_done_callback)
    if self._destroyed or not self._current_fmd then
        if on_done_callback then on_done_callback(false, "session destroyed") end
        return
    end

    if not force and self._current_page == self._last_upload_page then
        Log.debug("[Progress] 跳过上传: 页码未变化 page=" .. tostring(self._current_page))
        if on_done_callback then on_done_callback(true, "skip") end
        return
    end

    local fmd = self._current_fmd
    local upload_page = self._current_page + 1
    local upload_total = self._current_total
    -- 【会话令牌】本次上传所属的会话号（见下面上传成功分支）
    local upload_gen = self._session_gen

    Log.debug("[Progress] 上传进度: fmd=" .. tostring(fmd)
        .. " page=" .. tostring(upload_page) .. "/" .. tostring(upload_total)
        .. " force=" .. tostring(force == true))

    local function do_upload(retry_count)
        if self._destroyed then return end
        if not self.client then
            if on_done_callback then on_done_callback(false, "client unavailable") end
            return
        end
        local ok, result_ok, msg, resp_obj = pcall(function()
            return self.client:report_read_page(fmd, upload_page, upload_total)
        end)
        if not ok then
            local err = tostring(result_ok or "pcall exception")
            Log.warn("[Progress] report_read_page 调用异常:", err)
            if retry_count < 1 then
                Log.debug("[Progress] 重试 1 次")
                if ok_UIManager and UIManager then
                    UIManager:scheduleIn(1, function() do_upload(retry_count + 1) end)
                else
                    do_upload(retry_count + 1)
                end
                return
            end
            if on_done_callback then on_done_callback(false, err) end
            return
        end
        if result_ok then
            -- 【身份校验】只有「上传期间会话没换过」才把已上传页码落到本会话上。
            -- 否则 fmd 是旧书的、页码是当前会话的 → 把 A 的本地记录改成 B 的页，
            -- 同时把 B 的当前页标记成「已上传」而跳过它真正该有的那次上传。
            if self._session_gen ~= upload_gen then
                Log.warn("[Progress] 上传成功但会话已切换，跳过本地进度落盘 fmd=" .. tostring(fmd))
                if on_done_callback then on_done_callback(true, msg or "ok") end
                return
            end
            self._last_upload_ts = os.time()
            self._last_upload_page = self._current_page
            if self.bookshelf then
                self.bookshelf:save_vol_progress(fmd, self._current_page, self._current_total, os.time())
            end
            Log.debug("[Progress] 上传成功")
            if on_done_callback then on_done_callback(true, msg or "ok") end
        else
            Log.warn("[Progress] 上传失败:", tostring(msg or "unknown"))
            if retry_count < 1 then
                Log.debug("[Progress] 重试 1 次")
                if ok_UIManager and UIManager then
                    UIManager:scheduleIn(1, function() do_upload(retry_count + 1) end)
                else
                    do_upload(retry_count + 1)
                end
                return
            end
            if on_done_callback then on_done_callback(false, msg or "upload failed") end
        end
    end

    if ok_UIManager and UIManager then
        UIManager:scheduleIn(0.01, function() do_upload(0) end)
    else
        do_upload(0)
    end
end

--- 结束会话：停定时器 → 落盘本地进度 → 最后一次强制上传 → 标记销毁。
-- ⚠️ 历史 bug：原实现先把 `_destroyed` 置 true 再调 `_upload_now`，而 `_upload_now` / `do_upload`
-- 开头都会 `if self._destroyed then return end` → 这次「关闭时推送」永远是空操作。
-- 现在用 `_ending` 标记表示「正在收尾、尚未销毁」，让收尾上传能真正跑完。
-- @param opts table|nil { skip_upload = true } 只收尾不上传（Reader close_reader(false) 用）
function Progress:end_session(on_done_callback, opts)
    if self._destroyed or self._ending then
        if on_done_callback then on_done_callback(true, "already ended") end
        return
    end
    self._ending = true

    if self._timer_handle and ok_UIManager and UIManager then
        pcall(function() UIManager:unschedule(self._timer_handle) end)
        self._timer_handle = nil
    end

    local fmd = self._current_fmd
    if self.bookshelf and fmd then
        self.bookshelf:save_vol_progress(fmd, self._current_page, self._current_total, os.time())
    end

    local function finish(ok, msg)
        self._ending = false
        self._destroyed = true
        if on_done_callback then
            on_done_callback(ok, msg)
        end
    end

    if (opts and opts.skip_upload) or not fmd then
        Log.debug("[Progress] end_session: 跳过上传, fmd=" .. tostring(fmd))
        finish(true, "skip_upload")
        return
    end

    Log.debug("[Progress] end_session: 强制上传 fmd=" .. tostring(fmd)
        .. " page=" .. tostring(self._current_page))
    self:_upload_now(true, finish)
end

function Progress:manual_pull(on_done)
    if self._destroyed or not self._current_fmd then
        if on_done then on_done(false, nil, "session destroyed", nil) end
        return
    end

    local fmd = self._current_fmd
    local session_gen = self._session_gen
    Async.run(function()
        if not self.client then return nil end
        return self.client:query_vol_info(fmd)
    end, function(ok, vol_info, err)
        -- 【身份校验】会话已销毁 / 已换书 / 已换会话 → 结果作废。
        -- （原实现完全没有这道校验：拉取 A 的云端进度期间切到 B，
        --   A 的结果会当成 B 的进度返回给调用方。）
        if self._destroyed or self._session_gen ~= session_gen or self._current_fmd ~= fmd then
            Log.warn("[Progress] manual_pull 结果已过期（会话已切换），丢弃 fmd=" .. tostring(fmd))
            if on_done then on_done(false, nil, "session changed", nil) end
            return
        end
        if ok and vol_info then
            local cloud_page = tonumber(vol_info.last_readpage) or 0
            Log.debug("[Progress] manual_pull 成功, cloud_page=" .. tostring(cloud_page))
            if on_done then on_done(true, cloud_page, "ok", vol_info) end
        else
            Log.warn("[Progress] manual_pull 失败:", tostring(err or "unknown"))
            if on_done then on_done(false, nil, tostring(err or "pull failed"), nil) end
        end
    end, { timeout = 30, tag = "progress" })
end


return Progress
