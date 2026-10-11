local Log = require("koobone.logger")
local Progress = require("koobone.progress")
-- 用于 close_reader 取消本会话在途的异步请求（Async.cancel_tag("progress")）
local ok_Async, Async = pcall(require, "koobone.async")

local Reader = {}
Reader.__index = Reader

function Reader:new(plugin)
    local obj = {
        plugin = plugin,
        settings = plugin and plugin.settings,
        bookshelf = plugin and plugin.bookshelf,
        client = plugin and plugin.client,

        _current_vol = nil,
        -- 对外只读别名：shelf_view 的「手动上传云端进度」用它判断当前卷是否匹配。
        current_vol = nil,
        -- 【阅读会话令牌】每次 start_progress_session 自增；所有异步回调执行时比对，
        -- 不一致即放弃。作用等同 reading 的 Context.get_generation()：防止「切书 / 关书后
        -- 旧回调仍往当前会话里写」——数据可能对，但落到错误的书上。
        -- 注意 close_reader 也自增（会话已失效），且**不重置**，这样旧回调仍能识别自己过期。
        _session_gen = 0,
        -- 【会话归属】承载当前会话的那个 ReaderUI 实例（由该实例上的插件在 onReaderReady 时认领）。
        -- 见 claim_session / is_session_owner 的说明：判断「该不该结束会话」只能靠归属，
        -- 参数化地看「是不是 ReaderUI」会误杀。这里只弱引用语义，close_reader 会清空。
        _session_owner_ui = nil,
        _progress = nil,
        _progress_pull_timer = nil,
        _progress_push_timer = nil,
        _periodic_sync_cb = nil,
    }
    return setmetatable(obj, self)
end

--- 当前阅读会话的进度（对外只读）。
-- 进度来源是 Progress 对象同步维护的 last_page / total_pages。
-- @return number 当前页码（0 表示无会话）
-- @return number 总页数（0 表示未知）
function Reader:get_progress()
    if self._progress then
        return self._progress.last_page or 0, self._progress.total_pages or 0
    end
    return 0, 0
end

--- 本会话是否归这个 ui 实例所有（见 claim_session）。
-- @param ui 插件实例的 self.ui
-- @return boolean
function Reader:is_session_owner(ui)
    return ui ~= nil and self._session_owner_ui == ui
end

--- 由「承载本会话的 ReaderUI 实例上的插件」认领会话归属（在 onReaderReady 里调用）。
--
-- 为什么需要「归属」而不是「是不是 ReaderUI」：
--   main.lua:onCloseWidget 想表达的是「用户离开了正在读的这本书 → 推送最后一次进度」。
--   但 CloseWidget 会在**四种**完全不同的时刻播到插件：
--     ① 书架/文件管理器打开一本漫画 → FileManager:onShowingReader → FileManager:onClose()
--        → 此刻 open_comic 里刚 start_progress_session()，绝不能结束会话；
--     ② 阅读中换卷 → ReaderUI:showReader 先 broadcastEvent("ShowingReader")
--        → **旧** ReaderUI:onShowingReader → onClose(false)
--        → 而 open_comic 已经先 start_progress_session(新卷) 了 —— 同样不能结束会话；
--     ③ 用户退出阅读（真正该结束并上传的那一次）；
--     ④ 插件所在 ui 的其它关闭路径。
--   ①和②本质相同：都是「一个和当前会话无关的 ui 关闭了」；③ 是「承载会话的 ui 关闭了」。
--   所以判据必须是「归属」：只有 ③ 满足。
--   注：不能拿 document 判 —— ReaderUI:onClose 是 closeDocument()（document=nil）之后才
--   UIManager:close(self)，轮到插件时 document 早为 nil；也不能只看 ui.name == "ReaderUI"，
--   那会把 ② 一起算进去（旧 ReaderUI 也是 ReaderUI）。
--
-- ReaderReady 时机（已核对上游 readerui.lua）：ReaderUI:init() 内先 createPluginInstance +
-- registerModule（464-474 行），再 handleEvent(Event:new("ReaderReady"))（517 行）
-- —— 所以新实例一定能收到并认领。切换卷时旧实例的 onShowingReader 发生在
-- ReaderUI:new 之前，不会抢先认领。
-- @param ui 插件实例的 self.ui（ReaderUI）
function Reader:claim_session(ui)
    if not self._progress or not self._current_vol then
        return  -- 没有活动会话（例如用户打开的是非 Koobone 的书）：不认领
    end
    self._session_owner_ui = ui
end

function Reader:start_progress_session(vol)
    if not vol then return end

    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return end

    self._current_vol = vol
    self.current_vol = vol

    -- 【会话令牌】本次会话的号（见 _session_gen 的说明）
    self._session_gen = (self._session_gen or 0) + 1
    local session_gen = self._session_gen
    -- 【会话归属】新会话还没有承载它的 ReaderUI（那要等 showReader 之后 onReaderReady 认领）。
    -- 必须先清空：否则上一本书的 ReaderUI 实例仍挂在归属上，它的关闭就会误杀本次会话。
    self._session_owner_ui = nil

    local epub_path = nil
    if self.plugin and self.plugin.download then
        epub_path = self.plugin.download:_resolve_epub_path(vol, fmd, vol.file_md5)
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
        -- 【会话身份校验】异步回调：执行时当前会话可能已经是另一本书了。
        -- 比对令牌，过期就直接丢（同 reading 的 `Context.get_generation() ~= gen`）。
        if self._session_gen ~= session_gen then
            Log.debug("[KooboneReader] 云端进度回调已过期（会话已切换），忽略")
            return
        end
        if not self._current_vol then return end
        local local_total_cb = self._progress and self._progress.total_pages or total
        if local_total_cb > 0 and cloud_page_1based > 0 and cloud_page_1based <= local_total_cb then
            Log.info("[KooboneReader] 云端进度: " .. cloud_page_1based .. "/" .. local_total_cb)
        end
    end

    self._progress:start_session(fmd, start_page, total_pages, pulled_cb)

    self:_schedule_jump_start_page(fmd, start_page, total_pages, session_gen)

    if self._progress_pull_timer then
        return
    end

    self._progress_pull_timer = true

    local selfref = self
    -- @return boolean 是否应继续下一轮
    local function periodic_sync()
        -- 【会话身份校验】会话已结束 / 已切换 → 结束这条轮询链（见下方 tick 的说明）
        if selfref._session_gen ~= session_gen then
            return false
        end
        if not selfref._progress or not selfref._current_vol then return false end

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
        return true
    end

    local ok_sched, UIManager = pcall(require, "ui/uimanager")
    if ok_sched and UIManager and UIManager.scheduleIn then
        -- ⚠️ 这条链必须能停。原实现在链尾**无条件** scheduleIn(30, periodic_sync)，
        -- 于是每开一本书都会新起一条永不停止的 30s 定时器链：旧链虽然每轮都因
        -- `_current_vol == nil` 立刻 return，但它**从不消失**，开 N 本书 = N 条链
        -- 每 30s 各醒一次（墨水屏上就是白白唤醒 CPU）。
        -- 现在：令牌不一致 → periodic_sync 返回 false → 不再续链；
        -- close_reader 还会额外 unschedule 掉待执行的那一次。
        local tick
        tick = function()
            selfref._progress_push_timer = nil
            if periodic_sync() then
                selfref._progress_push_timer = true
                UIManager:scheduleIn(30, tick)
            end
        end
        selfref._progress_push_timer = true
        UIManager:scheduleIn(30, tick)
        selfref._periodic_sync_cb = tick
    end
end

-- ReaderUI:showReader 是异步创建实例，需等待 ReaderUI.instance.document 可用后再跳转
-- 重试最多 10s（每 0.2s 一次），成功跳转后停止重试
function Reader:_schedule_jump_start_page(fmd, target_page_1based, total_pages, session_gen)
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
        -- 会话已切换（切书 / 关书）：停止跳转。
        -- ⚠️ 光比 fmd 不够：关掉再打开**同一本书**时 fmd 相同，旧会话的重试链
        -- 会继续跳新会话的页（本项目 fmd 就是唯一书 id，这正是令牌存在的理由）。
        if session_gen and selfref._session_gen ~= session_gen then return end
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

    -- 【会话令牌】会话结束即作废：所有异步回调（云端进度拉取 / 跳页重试 / 30s 轮询链）
    -- 一比对令牌就自行放弃。计数器**不重置** —— 这样已发出去的旧回调仍能识别自己过期
    -- （与 reading 的 clear_reading_context 同样刻意不重置 generation）。
    self._session_gen = (self._session_gen or 0) + 1
    -- 【会话归属】同时解绑，本会话自此与任何 ui 无关：
    -- 换卷时 open_comic 会先调本函数给上一卷收尾，之后旧 ReaderUI 才关闭 ——
    -- 归属若不清空，旧 ReaderUI 的 onCloseWidget 会再触发一次 close_reader（虽然幂等，
    -- 但语义上是「已经结束的会话又被当成活动会话」）。
    self._session_owner_ui = nil

    -- 取消本会话所有在途的异步网络请求（云端进度拉取，tag="progress"）。
    -- 它们的 timeout 是 30s，不取消的话关掉阅读器后子进程还会继续跑完；
    -- 而且结果对已结束的会话毫无意义（即使回来了也会被上面的令牌挡掉）。
    if ok_Async and Async and Async.cancel_tag then
        pcall(function() Async.cancel_tag("progress") end)
    end

    -- 先把待执行的那次 30s 轮询取消掉（令牌比对是兜底，这里直接把手头的取消）
    if self._periodic_sync_cb then
        local ok_um, UM = pcall(require, "ui/uimanager")
        if ok_um and UM and UM.unschedule then
            pcall(function() UM:unschedule(self._periodic_sync_cb) end)
        end
        self._periodic_sync_cb = nil
    end

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
            -- 上传统一在 end_session() 里做（强制上传），此处不再单独调用 push_to_cloud，
            -- 否则会出现「关闭时推两次」。
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
        -- push_progress == false（插件 teardown 路径）只收尾、不上传；
        -- 否则 end_session 内部做最后一次强制上传。
        self._progress:end_session(nil, { skip_upload = (push_progress == false) })
        self._progress = nil
    end

    self._current_vol = nil
    self.current_vol = nil
    self._progress_pull_timer = nil
    self._progress_push_timer = nil
end

return Reader