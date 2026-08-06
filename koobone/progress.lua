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
    }
    return setmetatable(obj, self)
end

function Progress:start_session(fmd, initial_page_or_nil, total_pages, on_progress_pulled)
    if self._destroyed then return false end

    self._current_fmd = fmd
    self._current_page = tonumber(initial_page_or_nil) or 0
    self._current_total = tonumber(total_pages) or 0

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
            if self._destroyed or self._current_fmd ~= fmd then return end
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
        end, { timeout = 30 })
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

function Progress:update_page(page_idx, total_pages_opt)
    if self._destroyed or not self._current_fmd then return end

    self._current_page = tonumber(page_idx) or 0
    if total_pages_opt then
        self._current_total = tonumber(total_pages_opt) or self._current_total
    end

    _state.setCurrentPage(self._current_page)
    if self.bookshelf then
        self.bookshelf:touch_vol_read_time(self._current_fmd)
    end

    local interval = tonumber(self.settings:get_progress_upload_interval()) or 60
    local now_ts = os.time()
    local time_since_last = now_ts - self._last_upload_ts
    local page_changed = self._current_page ~= self._last_upload_page

    local trigger_a = (self._current_page % 10 == 0) and (self._last_upload_page ~= self._current_page)
    local trigger_b = (interval > 0) and (time_since_last > 2 * interval) and page_changed

    if trigger_a or trigger_b then
        Log.debug("[Progress] 立即触发上传: trigger_a=" .. tostring(trigger_a)
            .. " trigger_b=" .. tostring(trigger_b)
            .. " page=" .. tostring(self._current_page))
        self:_upload_now(false)
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

function Progress:end_session(on_done_callback)
    if self._timer_handle and ok_UIManager and UIManager then
        pcall(function() UIManager:unschedule(self._timer_handle) end)
        self._timer_handle = nil
    end

    self._destroyed = true

    local fmd = self._current_fmd
    if self.bookshelf and fmd then
        self.bookshelf:save_vol_progress(fmd, self._current_page, self._current_total, os.time())
    end

    Log.debug("[Progress] end_session: force upload fmd=" .. tostring(fmd)
        .. " page=" .. tostring(self._current_page))

    self:_upload_now(true, function(ok, msg)
        if on_done_callback then
            on_done_callback(ok, msg)
        end
    end)
end

function Progress:manual_pull(on_done)
    if self._destroyed or not self._current_fmd then
        if on_done then on_done(false, nil, "session destroyed", nil) end
        return
    end

    local fmd = self._current_fmd
    Async.run(function()
        if not self.client then return nil end
        return self.client:query_vol_info(fmd)
    end, function(ok, vol_info, err)
        if ok and vol_info then
            local cloud_page = tonumber(vol_info.last_readpage) or 0
            Log.debug("[Progress] manual_pull 成功, cloud_page=" .. tostring(cloud_page))
            if on_done then on_done(true, cloud_page, "ok", vol_info) end
        else
            Log.warn("[Progress] manual_pull 失败:", tostring(err or "unknown"))
            if on_done then on_done(false, nil, tostring(err or "pull failed"), nil) end
        end
    end, { timeout = 30 })
end

function Progress:manual_push(on_done)
    if self._destroyed then
        if on_done then on_done(false, "session destroyed") end
        return
    end
    self:_upload_now(true, on_done)
end

function Progress:destroy()
    if self._timer_handle and ok_UIManager and UIManager then
        pcall(function() UIManager:unschedule(self._timer_handle) end)
        self._timer_handle = nil
    end
    self._destroyed = true
    self._current_fmd = nil
    self.settings = nil
    self.client = nil
    self.bookshelf = nil
end

return Progress
