local Log = require("koobone.logger")
local _state = require("koobone.state")
local Progress = require("koobone.progress")

local Reader = {}
Reader.__index = Reader

function Reader:new(plugin)
    local obj = {
        plugin = plugin,
        settings = plugin and plugin.settings,
        bookshelf = plugin and plugin.bookshelf,
        client = plugin and plugin.client,

        _current_vol = nil,
        _progress = nil,
        _progress_pull_timer = nil,
        _progress_push_timer = nil,
    }
    return setmetatable(obj, self)
end

function Reader:start_progress_session(vol)
    if not vol then return end

    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return end

    self._current_vol = vol

    local epub_path = nil
    if self.plugin and self.plugin.download then
        epub_path = self.plugin.download:_epub_path(fmd, vol.file_md5)
    end

    -- ---- 进度来源：本地(LOCAL_VOL_INDEX) > 云端/API(vol.last_readpage) ----
    -- 用户要求：断网场景也要恢复到正确页码，所以优先本地
    local local_page = 0
    local local_total = 0
    if self.bookshelf then
        local info = nil
        local ok_get, cached_vol = pcall(function()
            return self.bookshelf:get_vol_by_fmd(fmd)
        end)
        if ok_get and cached_vol then
            local_page = tonumber(cached_vol.last_readpage) or 0
            local_total = tonumber(cached_vol.total_pages) or 0
        end
    end
    local api_page = tonumber(vol.last_readpage) or 0
    local api_total = tonumber(vol.total_pages or vol.count_page) or 0
    -- 取本地/API 中较新的进度（更大的页码/总页数）
    local total_pages = local_total > 0 and local_total or api_total
    if total_pages <= 0 and vol.file_size then
        total_pages = math.max(1, math.floor(tonumber(vol.file_size) / 1024))
    end
    local best_page = local_page >= api_page and local_page or api_page
    local start_page = best_page  -- 内部 1-based（periodic_sync 会读到 document.pos_page 即 1-based）
    if start_page < 0 then start_page = 0 end
    -- start_page 保持 1-based；下面调度跳转时用 1-based

    self._progress = Progress:new(self.settings, self.client, self.bookshelf)

    local function pulled_cb(cloud_page_1based, total, vol_info)
        if not self._current_vol then return end
        local local_total_cb = self._progress and self._progress.total_pages or total
        if local_total_cb > 0 and cloud_page_1based > 0 and cloud_page_1based <= local_total_cb then
            Log.info("[KooboneReader] 云端进度: " .. cloud_page_1based .. "/" .. local_total_cb)
        end
    end

    self._progress:start_session(fmd, start_page, total_pages, pulled_cb)

    self:_schedule_jump_start_page(fmd, start_page, total_pages)

    if self._progress_pull_timer then
        return
    end

    self._progress_pull_timer = true

    local selfref = self
    local function periodic_sync()
        if not selfref._progress or not selfref._current_vol then return end

        local ok_ReaderUI, ReaderUI = pcall(require, "apps/reader/readerui")
        local reader_inst = ok_ReaderUI and ReaderUI and ReaderUI.instance
        local cur_page = 0
        if reader_inst and reader_inst.document then
            cur_page = reader_inst.document.pos_page or 0
            if cur_page <= 0 and reader_inst.view and reader_inst.view.view then
                local ok_pg, p = pcall(function()
                    return reader_inst.view.view.state.page or 0
                end)
                if ok_pg then cur_page = p end
            end
        end
        if selfref._progress and cur_page > 0 then
            selfref._progress:update_local_progress(cur_page, total_pages)
        end
        -- 写 LOCAL_VOL_INDEX（持久化来源，断网可用）
        if cur_page > 0 and selfref.bookshelf then
            local fmd_cur = tostring(selfref._current_vol and (selfref._current_vol.file_md5 or selfref._current_vol.fmd) or "")
            if fmd_cur ~= "" then
                pcall(function()
                    selfref.bookshelf:save_vol_progress(
                        fmd_cur,
                        cur_page,       -- 1-based 页码（save_vol_progress 接收 1-based，last_readpage）
                        total_pages,
                        os.time()       -- 更新本地阅读时间
                    )
                end)
            end
        end
    end

    local ok_sched, UIManager = pcall(require, "ui/uimanager")
    if ok_sched and UIManager and UIManager.scheduleIn then
        self._progress_push_timer = true
        UIManager:scheduleIn(30, function()
            periodic_sync()
            selfref._progress_push_timer = nil
            -- 继续下一轮 30s 轮询（之前是单次，改持续轮询）
            UIManager:scheduleIn(30, periodic_sync)
        end)
        self._periodic_sync_cb = periodic_sync
    end
end

-- ReaderUI:showReader 是异步创建实例，需等待 ReaderUI.instance.document 可用后再跳转
-- 重试最多 10s（每 0.2s 一次），成功跳转后停止重试
function Reader:_schedule_jump_start_page(fmd, target_page_1based, total_pages)
    if not target_page_1based or target_page_1based <= 1 then
        return  -- 第 1 页无需跳转
    end
    local ok_sched, UIManager = pcall(require, "ui/uimanager")
    if not ok_sched or not UIManager or not UIManager.scheduleIn then return end

    local max_tries = 50  -- 0.2s * 50 = 10s
    local tries = 0
    local selfref = self

    local function try_jump()
        tries = tries + 1
        -- 卷已变了，停止跳转
        if not selfref._current_vol then return end
        local cur_fmd = tostring(selfref._current_vol.file_md5 or selfref._current_vol.fmd or "")
        if cur_fmd ~= fmd then return end

        local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
        if not ok_r or not ReaderUI or not ReaderUI.instance then
            if tries < max_tries then
                UIManager:scheduleIn(0.2, try_jump)
            end
            return
        end
        local rinst = ReaderUI.instance
        -- 有文档 + 总页数大于目标页 → 可以跳
        local can_jump = false
        local doc_total = 0
        if rinst.document then
            if rinst.document.pos_page and rinst.document.pos_page > 0 then
                can_jump = true
            end
            if rinst.document.getPageCount then
                local ok_tc, tc = pcall(function() return rinst.document:getPageCount() end)
                if ok_tc and tc then doc_total = tc end
            end
            if rinst.view and rinst.view.view and rinst.view.view.state and rinst.view.view.state.page and rinst.view.view.state.page > 0 then
                can_jump = true
            end
        end
        -- 如果目标页还大于文档总页数（文档还在加载），延迟
        if doc_total > 0 and target_page_1based > doc_total then
            if tries < max_tries then
                UIManager:scheduleIn(0.2, try_jump)
            end
            return
        end
        if not can_jump and tries < max_tries then
            UIManager:scheduleIn(0.2, try_jump)
            return
        end

        -- 目标：1-based 页码 N → goto 1-based
        local goto_ok = false
        if rinst.gotoPage then
            local ok_g, _ = pcall(function() rinst:gotoPage(target_page_1based) end)
            if ok_g then goto_ok = true end
        end
        if not goto_ok and rinst.view and rinst.view.gotoPage then
            pcall(function() rinst.view:gotoPage(target_page_1based) end)
        end
        if not goto_ok and rinst.rolling_page and type(rinst.rolling_page) == "number" then
            pcall(function()
                if rinst.setRollingPage then
                    rinst:setRollingPage(target_page_1based)
                end
            end)
        end
        Log.info("[KooboneReader] 跳转到上次阅读页 " .. tostring(target_page_1based)
            .. "/" .. tostring(total_pages) .. " fmd=" .. fmd)
    end
    UIManager:scheduleIn(0.2, try_jump)
end

function Reader:close_reader(push_progress)
    if not self._current_vol then return end

    if push_progress ~= false and self._progress then
        local ok_ReaderUI, ReaderUI = pcall(require, "apps/reader/readerui")
        local reader_inst = ok_ReaderUI and ReaderUI and ReaderUI.instance
        local cur_page = 0
        if reader_inst and reader_inst.document then
            cur_page = reader_inst.document.pos_page or 0
            if cur_page <= 0 and reader_inst.view and reader_inst.view.view then
                local ok_pg, p = pcall(function()
                    return reader_inst.view.view.state.page or 0
                end)
                if ok_pg then cur_page = p end
            end
        end
        if cur_page <= 0 and self._progress then
            cur_page = tonumber(self._progress.last_page) or 0
        end
        if cur_page > 0 then
            self._progress:update_local_progress(cur_page, self._progress.total_pages)
            self._progress:push_to_cloud()
            -- 写 LOCAL_VOL_INDEX（持久化到 shelf_cache，断网可用）
            if self.bookshelf then
                local fmd_cur = tostring(self._current_vol.file_md5 or self._current_vol.fmd or "")
                if fmd_cur ~= "" then
                    pcall(function()
                        self.bookshelf:save_vol_progress(
                            fmd_cur,
                            cur_page,
                            self._progress.total_pages,
                            os.time()
                        )
                    end)
                end
            end
        end
    end

    if self._progress then
        self._progress:end_session()
        self._progress = nil
    end

    self._current_vol = nil
    self._progress_pull_timer = nil
    self._progress_push_timer = nil
end

return Reader