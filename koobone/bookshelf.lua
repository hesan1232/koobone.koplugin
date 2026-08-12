local H = require("koobone.helper")
local Log = require("koobone.logger")
local state = require("koobone.state")

-- ============================================================
-- 对齐 fanqie 两级缓存架构：
--   书架（顶层视图） = series_list.php  → 系列列表（系列=漫画本体）
--   目录（点进系列） = vol_list.php?sid= → 该系列的卷列表（卷=章节）
-- ============================================================

-- L2: 系列列表内存缓存（书架主数据源，进程生命周期内常驻）
-- 每次读取返回浅拷贝，避免调用方 table.sort 污染原始顺序
local SERIES_MEM_CACHE = nil
local SERIES_MEM_TS = 0

-- 按系列的卷列表缓存（目录数据源，key=series_id）
-- 目录缓存优先走 client.lua 的 L1 API 缓存；
-- 这里再存一层加载后（含本地进度、cover_path 填充）的对象，省重复序列化
-- 重要：缓存内保存的是 UNSORTED（API 返回原始顺序）数据，排序在 get_series_vols return 前才做。
-- 这样切换排序方式不会导致缓存 miss，也不需要清空 SERIES_VOLS_MEM。
local SERIES_VOLS_MEM = {}
-- 每个系列的缓存 freshness 标记：为 true 表示后台应该刷新（TTL 过期或强制刷新），
-- 但当前仍可返回旧数据秒开。
local SERIES_VOLS_DIRTY = {}

-- 本地进度/阅读状态索引（fmd → vol 元信息）
-- 刷新书架后用于给系列列表/目录回填 _local_last_read / last_readpage 等本地持久数据
local LOCAL_VOL_INDEX = {}  -- key = fmd, value = table with last_readpage etc

local Bookshelf = {}
Bookshelf.__index = Bookshelf

function Bookshelf:new(settings, client)
    local obj = {
        settings = settings,
        client = client,
        vols = {},           -- deprecated: 不再存全局 vols（按需按系列拉）
        series_map = {},     -- deprecated: 不再从全局 vols 派生
        covers = {},
        dirty = true,
        shelf_cache_file = H.get_data_dir() .. "/shelf_cache.lua",
        _last_save_ts = 0,
        _pending_changes = 0,
    }
    H.make_dir(H.get_data_dir())
    return setmetatable(obj, self)
end

-- ============================================================
-- L2 内存缓存：浅拷贝工具，返回独立副本供调用方排序
-- ============================================================
local function shallow_copy_list(tbl)
    if not tbl then return {} end
    local copy = {}
    for i, b in ipairs(tbl) do
        local nb = {}
        for k, v in pairs(b) do
            nb[k] = v
        end
        copy[i] = nb
    end
    return copy
end

-- ============================================================
-- L3 文件缓存：Lua table 序列化（loadfile 直接执行，零解析开销）
-- 存：系列列表 + 本地进度索引（fmd → 进度元数据）
-- ============================================================
local function escape_lua_string(s)
    if type(s) ~= "string" then return tostring(s) end
    -- 完整转义：\ " 换行 回车 tab 以及控制字符
    local r = string.gsub(s, "\\", "\\\\")
    r = string.gsub(r, '"', '\\"')
    r = string.gsub(r, "\n", "\\n")
    r = string.gsub(r, "\r", "\\r")
    r = string.gsub(r, "\t", "\\t")
    r = string.gsub(r, "[%z\001-\031]", function(c)
        return string.format("\\%03d", string.byte(c))
    end)
    return r
end

local function serialize_table_list_to_lua(list, saved_at, label, vol_index, vols_by_series)
    -- 通用的 table list 序列化器，同时可选地把 LOCAL_VOL_INDEX 和 SERIES_VOLS_MEM 持久化
    -- label: "series" 或 "vols"
    -- vol_index: LOCAL_VOL_INDEX（fmd→进度信息）
    -- vols_by_series: SERIES_VOLS_MEM（series_id→{vols=..., ts=...}）
    local lines = {}
    table.insert(lines, "return {")
    table.insert(lines, "  saved_at = " .. tostring(saved_at or os.time()) .. ",")
    table.insert(lines, "  " .. label .. " = {")
    for i, v in ipairs(list) do
        local fields = {}
        local keys = {}
        for k, _ in pairs(v) do
            table.insert(keys, k)
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local val = v[k]
            local t = type(val)
            if t == "string" then
                table.insert(fields, tostring(k) .. '="' .. escape_lua_string(val) .. '"')
            elseif t == "number" then
                table.insert(fields, tostring(k) .. "=" .. tostring(val))
            elseif t == "boolean" then
                table.insert(fields, tostring(k) .. "=" .. (val and "true" or "false"))
            end
        end
        table.insert(lines, "    {" .. table.concat(fields, ",") .. "},")
    end
    table.insert(lines, "  },")
    -- 可选：本地进度索引
    if vol_index then
        table.insert(lines, "  vol_index = {")
        local fmd_keys = {}
        for fmd, _ in pairs(vol_index) do table.insert(fmd_keys, fmd) end
        table.sort(fmd_keys)
        for _, fmd in ipairs(fmd_keys) do
            local info = vol_index[fmd]
            local fields = {}
            table.insert(fields, 'fmd="' .. escape_lua_string(tostring(fmd)) .. '"')
            local keys2 = {}
            for k2, _ in pairs(info) do
                if k2 ~= "fmd" then table.insert(keys2, k2) end
            end
            table.sort(keys2)
            for _, k in ipairs(keys2) do
                local val = info[k]
                local t = type(val)
                if t == "string" then
                    table.insert(fields, tostring(k) .. '="' .. escape_lua_string(val) .. '"')
                elseif t == "number" then
                    table.insert(fields, tostring(k) .. "=" .. tostring(val))
                elseif t == "boolean" then
                    table.insert(fields, tostring(k) .. "=" .. (val and "true" or "false"))
                end
            end
            table.insert(lines, "    {" .. table.concat(fields, ",") .. "},")
        end
        table.insert(lines, "  },")
    end
    -- 可选：按系列的卷列表缓存（vols_by_series），重启后恢复目录缓存
    if vols_by_series then
        table.insert(lines, "  vols_by_series = {")
        local sids = {}
        for sid, _ in pairs(vols_by_series) do table.insert(sids, sid) end
        table.sort(sids)
        for _, sid in ipairs(sids) do
            local entry = vols_by_series[sid]
            local vols = entry and entry.vols or {}
            table.insert(lines, '    ["' .. escape_lua_string(tostring(sid)) .. '"] = {')
            for _, v in ipairs(vols) do
                local fields = {}
                local keys3 = {}
                for k3, _ in pairs(v) do
                    table.insert(keys3, k3)
                end
                table.sort(keys3)
                for _, k in ipairs(keys3) do
                    local val = v[k]
                    local t = type(val)
                    if t == "string" then
                        table.insert(fields, tostring(k) .. '="' .. escape_lua_string(val) .. '"')
                    elseif t == "number" then
                        table.insert(fields, tostring(k) .. "=" .. tostring(val))
                    elseif t == "boolean" then
                        table.insert(fields, tostring(k) .. "=" .. (val and "true" or "false"))
                    end
                end
                table.insert(lines, "      {" .. table.concat(fields, ",") .. "},")
            end
            table.insert(lines, "    },")
        end
        table.insert(lines, "  },")
    end
    table.insert(lines, "}")
    return table.concat(lines, "\n")
end

local function get_shelf_cache_path(settings)
    return H.get_data_dir() .. "/shelf_cache.lua"
end

-- save_shelf_cache(series_list): 书架主数据（系列）持久化 + 本地进度索引持久化
local function save_shelf_cache(self, series_list)
    series_list = series_list or {}
    local saved_at = os.time()

    -- L2: 写内存缓存（浅拷贝保存原始顺序）
    SERIES_MEM_CACHE = shallow_copy_list(series_list)
    SERIES_MEM_TS = saved_at

    -- L3: 写文件缓存（Lua table 格式）
    if #series_list == 0 and H.file_exists(self.shelf_cache_file) then
        Log.warn("save_shelf_cache: series 为空但缓存已存在，跳过防止覆盖")
        return false
    end

    -- 把本地进度索引 + 按系列的卷列表缓存 一起持久化
    -- vols_by_series 重启后恢复目录缓存，避免每次进目录都打 API
    local content = serialize_table_list_to_lua(series_list, saved_at, "series", LOCAL_VOL_INDEX, SERIES_VOLS_MEM)
    local tmp_path = self.shelf_cache_file .. ".tmp"
    local f = io.open(tmp_path, "w")
    if not f then
        Log.error("save_shelf_cache: 无法写入临时文件")
        return false
    end
    f:write(content)
    f:close()
    local ok, err = os.rename(tmp_path, self.shelf_cache_file)
    if ok then
        Log.debug("书架缓存已写入(内存+文件), ", #series_list, "系列")
        self._last_save_ts = saved_at
        self._pending_changes = 0
        return true
    else
        Log.error("书架缓存原子重命名失败:", tostring(err))
        os.remove(tmp_path)
        return false
    end
end

local FILE_CACHE_TTL_SEC = 24 * 60 * 60  -- 24h（与 fanqie 一致）

-- 加载书架缓存：返回 series_list（浅拷贝），同步回填 LOCAL_VOL_INDEX
local function load_shelf_cache(self)
    -- L2 内存缓存
    if SERIES_MEM_CACHE and #SERIES_MEM_CACHE > 0 then
        Log.debug("load_shelf_cache: 命中内存缓存, ", #SERIES_MEM_CACHE, "系列")
        return shallow_copy_list(SERIES_MEM_CACHE)
    end

    -- L3 文件缓存
    if not H.file_exists(self.shelf_cache_file) then
        Log.info("load_shelf_cache: 文件缓存不存在")
        return {}
    end
    local ok, chunk = pcall(function()
        return loadfile(self.shelf_cache_file)
    end)
    if not ok or type(chunk) ~= "function" then
        Log.warn("load_shelf_cache: loadfile 失败，移除损坏缓存:", tostring(chunk))
        os.remove(self.shelf_cache_file)
        return {}
    end
    local poke_ok, data = pcall(chunk)
    if not poke_ok or not data then
        Log.warn("load_shelf_cache: 缓存文件结构损坏，移除")
        os.remove(self.shelf_cache_file)
        return {}
    end

    local saved_at = tonumber(data.saved_at) or 0
    if os.time() - saved_at > FILE_CACHE_TTL_SEC then
        Log.info("load_shelf_cache: 文件缓存已过期(>24h)，忽略")
        return {}
    end

    -- 兼容旧缓存：旧缓存存的是 vols；新缓存存的是 series + vol_index
    if data.vols and not data.series then
        -- 旧格式（vols）：降级处理，不回填 L2（强制下次走 API 拉）
        Log.info("load_shelf_cache: 检测到旧 vols 格式，暂不使用")
        return {}
    end

    local series = data.series or {}

    -- 检测旧缓存 bug：之前 seriesid="" 时 id 会写成空字符串，
    -- 导致封面文件名全是 "series_.jpg"、目录查询失败。
    -- 发现 id 为空的 series → 废弃旧缓存，强制走 API 重新拉取
    local has_bad_id = false
    for _, s in ipairs(series) do
        local sid = tostring(s.id or "")
        if sid == "" then
            has_bad_id = true
            break
        end
    end
    if has_bad_id then
        Log.warn("load_shelf_cache: 检测到旧缓存(series.id 为空)，废弃重拉")
        os.remove(self.shelf_cache_file)
        return {}
    end

    -- 回填本地进度索引
    if data.vol_index then
        for _, info in ipairs(data.vol_index) do
            local fmd = tostring(info.fmd or "")
            if fmd ~= "" then
                LOCAL_VOL_INDEX[fmd] = info
            end
        end
        Log.info("load_shelf_cache: 加载本地进度索引, 共", #data.vol_index, "条")
    end

    -- 回填按系列的卷列表缓存（vols_by_series）
    -- 重启后恢复目录缓存，避免每次进目录都打 API
    -- 修复：cache key 不再绑定 sort（排序在 get_series_vols return 前才做，避免切 sort 导致全 miss）
    if data.vols_by_series then
        local count_series = 0
        local count_vols = 0
        for sid, vols in pairs(data.vols_by_series) do
            if type(vols) == "table" and #vols > 0 then
                SERIES_VOLS_MEM[sid] = { vols = vols, ts = saved_at }
                -- 回填 state.directory_cache：纯 sid 为 key，不绑定 sort
                state.setDirectoryCache(sid, vols)
                count_series = count_series + 1
                count_vols = count_vols + #vols
            end
        end
        Log.info("load_shelf_cache: 加载目录缓存, ", count_series, "系列,", count_vols, "卷")
    end

    -- L3 → L2
    SERIES_MEM_CACHE = shallow_copy_list(series)
    SERIES_MEM_TS = saved_at
    Log.info("load_shelf_cache: 命中文件缓存并回填内存, ", #series, "系列")
    return shallow_copy_list(series)
end

local function clear_shelf_file_cache(self)
    if H.file_exists(self.shelf_cache_file) then
        os.remove(self.shelf_cache_file)
    end
end

-- 三层缓存同步清理
function Bookshelf:clearShelfCache()
    -- L1: client 层 API 短缓存
    if self.client then
        if self.client.clearVolListCache then
            self.client:clearVolListCache()
        end
        if self.client.clearSeriesListCache then
            self.client:clearSeriesListCache()
        end
    end
    -- L2: 显示层内存缓存
    SERIES_MEM_CACHE = nil
    SERIES_MEM_TS = 0
    SERIES_VOLS_MEM = {}
    LOCAL_VOL_INDEX = {}
    state.clearShelfVols()
    -- L3: 文件持久化缓存
    clear_shelf_file_cache(self)
    -- 衍生缓存同步清理
    state.invalidateDirectoryCache()
    state.invalidateDownloadedChapters()
    self.vols = {}
    self.dirty = true
    Log.info("Bookshelf.clearShelfCache: 三层缓存已清理")
end

-- ============================================================
-- 对外接口
-- ============================================================
-- 仅检查封面文件是否已存在（不触发下载），供 build_items 快速渲染用
function Bookshelf:check_cover_exists(vol)
    if not vol then return nil end
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return nil end
    if self.covers[fmd] then return self.covers[fmd] end
    local covers_dir = H.get_covers_dir()
    local cover_path = H.join_path(covers_dir, fmd .. ".jpg")
    if H.file_exists(cover_path) then
        self.covers[fmd] = cover_path
        return cover_path
    end
    return nil
end

function Bookshelf:refresh(force)
    Log.debug("Bookshelf:refresh force=", force)
    if not force then
        local cached = load_shelf_cache(self)
        if cached and #cached > 0 then
            state.setShelfVols(cached)
            Log.info("Bookshelf:refresh 使用内存/文件缓存, 共", #cached, "系列")
            return cached, nil
        end
    else
        -- force=true：清文件缓存（load_shelf_cache 自然命中失败），同时清本地 series/目录 内存缓存
        clear_shelf_file_cache(self)
        SERIES_MEM_CACHE = nil
        SERIES_MEM_TS = 0
        SERIES_VOLS_MEM = {}
        if self.client and self.client.clearSeriesListCache then
            pcall(function() self.client:clearSeriesListCache() end)
        end
        if self.client and self.client.clearVolListCache then
            pcall(function() self.client:clearVolListCache() end)
        end
    end

    local sort_key = self.settings:get_shelf_sort()
    -- fanqie 对齐：书架主数据源 = series_list.php
    local ok, series_or_err = pcall(function()
        return self.client:get_series_list({ sort = sort_key, force = force and true or false })
    end)

    if not ok then
        local err = tostring(series_or_err)
        Log.error("Bookshelf:refresh 拉取系列列表失败:", err)
        return nil, err
    end

    local raw_series = series_or_err or {}

    -- 回填本地进度信息（last_read、last_readpage、total_pages）
    for _, s in ipairs(raw_series) do
        local info = LOCAL_VOL_INDEX["series:" .. tostring(s.id or "")]
        if info then
            if info._local_last_read then
                s._local_last_read = info._local_last_read
            end
        end
    end

    -- 双写：内存 + 文件
    save_shelf_cache(self, raw_series)
    -- state 层同步（供 shelf_view、download 等模块快速查）
    state.setShelfVols(raw_series)
    -- 目录缓存、章节索引缓存（书架刷新后可能系列结构改变）
    state.invalidateDirectoryCache()
    state.invalidateDownloadedChapters()
    SERIES_VOLS_MEM = {}  -- 目录缓存全部失效
    Log.info("Bookshelf:refresh 完成, 共", #raw_series, "系列")
    return raw_series, nil
end

function Bookshelf:load_local_cache()
    Log.debug("Bookshelf:load_local_cache")
    local series = load_shelf_cache(self)
    if series and #series > 0 then
        state.setShelfVols(series)
        return series
    end
    Log.info("书架缓存为空")
    return {}
end

function Bookshelf:ensure_loaded()
    -- ensure_loaded：确保书架（系列列表）已加载（只看缓存，不阻塞打 API）
    -- 首先看内存里有没有，然后看文件缓存，都没有就返回空
    -- 调用方（main.lua showBookshelf）负责后台 Async.run(refresh) 拉取
    if SERIES_MEM_CACHE and #SERIES_MEM_CACHE > 0 then
        return shallow_copy_list(SERIES_MEM_CACHE)
    end
    local series = self:load_local_cache()
    if series and #series > 0 then
        return series
    end
    -- 缓存为空：返回空，不打 API（避免阻塞 UI）
    return {}
end

function Bookshelf:get_series_list()
    local series = self:ensure_loaded()
    -- 排序
    local sort_key = self.settings:get_shelf_sort()
    if sort_key == "vol_name" then
        table.sort(series, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    elseif sort_key == "last_read" then
        table.sort(series, function(a, b)
            local ta = a._local_last_read or a._max_last_read or 0
            local tb = b._local_last_read or b._max_last_read or 0
            if ta ~= tb then return ta > tb end
            return (a.last_update_time or tonumber(a.update_time) or 0)
                 > (b.last_update_time or tonumber(b.update_time) or 0)
        end)
    else
        table.sort(series, function(a, b)
            return (a.last_update_time or tonumber(a.update_time) or 0)
                 > (b.last_update_time or tonumber(b.update_time) or 0)
        end)
    end
    return series
end

-- 检查该系列的目录缓存是否"过期但有旧数据可用"
-- stale 条件：SERIES_VOLS_MEM[sid] 存在但 ts 超过 TTL（24h），或者标记为 dirty
function Bookshelf:is_series_vols_stale(series_id)
    if not series_id or series_id == "" then return false end
    local sid = tostring(series_id)
    if SERIES_VOLS_DIRTY[sid] then return true end
    local mem = SERIES_VOLS_MEM[sid]
    if not mem or not mem.ts then return false end
    return (os.time() - mem.ts) > 24 * 60 * 60
end

-- 只查缓存（L1/L2/L3），不触发 API 请求
-- 返回: vols_copy（浅拷贝+排序）或 nil（缓存全 miss）
-- 用于 show_series_chapter_dialog 避免同步阻塞打 API 导致 UI 卡死
function Bookshelf:peek_series_vols(series_id)
    if not series_id or series_id == "" then return nil end
    local sid = tostring(series_id)

    -- L1: 内存缓存
    local mem = SERIES_VOLS_MEM[sid]
    if mem and mem.vols and #mem.vols > 0 then
        local result = shallow_copy_list(mem.vols)
        return self:_sort_vols_catalog(result)
    end

    -- L2: state 目录缓存
    local cached = state.getDirectoryCache(sid)
    if cached and type(cached) == "table" and #cached > 0 then
        SERIES_VOLS_MEM[sid] = { vols = cached, ts = os.time() }
        local result = shallow_copy_list(cached)
        return self:_sort_vols_catalog(result)
    end

    -- L3: 磁盘 vols_by_series（shelf_cache.lua）
    if self.shelf_cache_file and H.file_exists(self.shelf_cache_file) then
        local ok_lf, chunk = pcall(function() return loadfile(self.shelf_cache_file) end)
        if ok_lf and type(chunk) == "function" then
            local ok_pk, data = pcall(chunk)
            if ok_pk and data and data.vols_by_series then
                local old_vols = data.vols_by_series[sid]
                if type(old_vols) == "table" and #old_vols > 0 then
                    SERIES_VOLS_MEM[sid] = { vols = old_vols, ts = (data.saved_at or 0) }
                    state.setDirectoryCache(sid, old_vols)
                    SERIES_VOLS_DIRTY[sid] = true
                    local result = shallow_copy_list(old_vols)
                    return self:_sort_vols_catalog(result)
                end
            end
        end
    end

    return nil  -- 缓存全 miss
end

function Bookshelf:get_series_vols(series_id, opts)
    opts = opts or {}
    local force = opts.force == true
    if not series_id or series_id == "" then
        return {}
    end
    local sid = tostring(series_id)
    -- 卷目录排序独立：永远按卷序号升序（漫画章节顺序）
    -- 书架 sort_key（self.settings:get_shelf_sort()）只影响系列列表，不影响卷目录
    -- 这样用户书架按 time_update 最近阅读排，进去目录依然是 第1卷→第2卷→... 正确顺序

    -- L1: 内存缓存（client.lua 还会再做一层 API 短缓存，此处是"本地化后对象"缓存）
    -- 注意：缓存中保存的是 UNSORTED 原始数据，排序在 return 前 shallow_copy 后做，
    -- 保证切 sort 不会清空缓存，也不会污染原始缓存顺序。
    local mem_cache = SERIES_VOLS_MEM[sid]
    if not force and mem_cache and mem_cache.vols and #mem_cache.vols > 0 then
        -- 缓存命中：返回浅拷贝副本 + sort（不污染缓存）
        Log.debug("get_series_vols: 命中内存缓存, series=", sid, "count=", #mem_cache.vols,
            "stale=", self:is_series_vols_stale(sid))
        local result = shallow_copy_list(mem_cache.vols)
        return self:_sort_vols_catalog(result)
    end

    -- L2: state 目录缓存（纯 sid 为 key，不绑定 sort；TTL 24h）
    if not force then
        local cached = state.getDirectoryCache(sid)
        if cached and type(cached) == "table" and #cached > 0 then
            Log.debug("get_series_vols: 命中state目录缓存, series=", sid, "count=", #cached)
            -- 回填 L1
            SERIES_VOLS_MEM[sid] = { vols = cached, ts = os.time() }
            local result = shallow_copy_list(cached)
            return self:_sort_vols_catalog(result)
        end
    end

    -- L3: 磁盘 vols_by_series（shelf_cache.lua，重启后已经 load_shelf_cache 回填到了 L1）
    -- 如果 L1/L2 都 miss，但 shelf_cache 文件里有 vols_by_series[sid] 旧数据，
    -- 先返回旧数据秒开，再标记 dirty，让调用方后台刷新（stale-while-revalidate）
    if not force and H.file_exists(self.shelf_cache_file) then
        local ok_lf, chunk = pcall(function() return loadfile(self.shelf_cache_file) end)
        if ok_lf and type(chunk) == "function" then
            local ok_pk, data = pcall(chunk)
            if ok_pk and data and data.vols_by_series then
                local old_vols = data.vols_by_series[sid]
                if type(old_vols) == "table" and #old_vols > 0 then
                    -- 有旧磁盘数据：立刻回填 L1/L2，返回秒开，同时标记 dirty
                    Log.info("get_series_vols: L1/L2 miss，命中磁盘旧目录缓存, series=",
                        sid, "count=", #old_vols, " → 秒开 + 后台待刷新")
                    -- 回填 L1
                    SERIES_VOLS_MEM[sid] = { vols = old_vols, ts = (data.saved_at or 0) }
                    -- 回填 L2
                    state.setDirectoryCache(sid, old_vols)
                    -- 标记 dirty：调用方可后台调 get_series_vols(force=true) 刷新
                    SERIES_VOLS_DIRTY[sid] = true
                    local result = shallow_copy_list(old_vols)
                    return self:_sort_vols_catalog(result)
                end
            end
        end
    end

    -- ============================================================
    -- L4: 打 API 拉取（缓存全 miss 或 force=true）
    -- ============================================================
    -- 查找 series 信息（sna + api_sid）
    -- api_sid 是原始 seriesid（可能为空），vol_list.php 查询时用它
    -- sid 是 fallback 后的 id（系列名或 seriesid），用于书架标识/缓存 key
    local series_title = ""
    local api_sid = ""
    local series_list = self:ensure_loaded()
    for _, s in ipairs(series_list) do
        if tostring(s.id or "") == sid then
            series_title = s.title or ""
            api_sid = s.api_sid or ""
            break
        end
    end

    -- 拉该系列的卷列表（目录）：
    --   seriesid 非空：vol_list.php?sid=KMOE:20798&sna=日月同錯
    --   seriesid 为空：vol_list.php?sid=&sna=地獄樂（只靠 sna 查）
    local vols = {}
    if self.client then
        local ok_v, vret = pcall(function()
            return self.client:get_vol_list({
                sort = sort_key,
                sid = api_sid,
                sna = series_title,
            })
        end)
        if ok_v and vret then
            vols = vret
        else
            Log.warn("get_series_vols: client.get_vol_list 失败, sid=", sid, "err=", tostring(vret))
        end
    end

    -- 强制注入正确的 series_id 和 sna
    -- normalize_vol_item 从 API 字段推断 series_id，但 vol_list.php?sid=xxx 返回的卷
    -- 可能不带 vol_seriesid 字段，导致 series_id 回退成系列名（错误的 key）
    -- 这里用查询时传入的 sid 覆盖，确保 is_vol_downloaded / 预下载 / 批量下载用的 key 一致
    for _, v in ipairs(vols) do
        v.series_id = sid
        if series_title ~= "" then
            v.series = v.series ~= "" and v.series or series_title
        end
    end

    -- 回填本地进度
    for _, v in ipairs(vols) do
        local fmd = tostring(v.file_md5 or v.fmd or "")
        local info = LOCAL_VOL_INDEX[fmd]
        if info then
            if info.last_readpage then v.last_readpage = info.last_readpage end
            if info.total_pages then v.total_pages = info.total_pages end
            if info._local_last_read then v._local_last_read = info._local_last_read end
        end
    end

    -- 写回 UNSORTED 缓存（不 sort！排序在 return 前通过 _sort_vols 对浅拷贝做）
    local now = os.time()
    SERIES_VOLS_MEM[sid] = { vols = vols, ts = now }
    SERIES_VOLS_DIRTY[sid] = false
    state.setDirectoryCache(sid, vols)
    -- 持久化到文件：vols_by_series 一起写入 shelf_cache.lua
    pcall(function() self:_save_shelf_cache() end)
    Log.info("get_series_vols: API加载完成, series=", sid, "count=", #vols, "force=", tostring(force))

    -- 返回浅拷贝 + sort（固定卷目录顺序，不跟随书架 sort）
    local result = shallow_copy_list(vols)
    return self:_sort_vols_catalog(result)
end

-- 内部：卷目录排序（独立于书架排序，只用于 get_series_vols 返回前）
-- 规则：永远按卷序号（vol_snumber）升序，代表漫画章节顺序 第1卷→第2卷...
--       time_update 不参与排序——用户明确："time_update时间最新代表当前阅读到这本书"，只用于⭐标记，不参与卷目录排序
--       无 vol_snumber 时 fallback 到卷名称（title/vol_name）字典序，保证稳定
function Bookshelf:_sort_vols_catalog(vols)
    if not vols or #vols <= 1 then return vols end
    table.sort(vols, function(a, b)
        local sa = tonumber(a.vol_snumber) or 0
        local sb = tonumber(b.vol_snumber) or 0
        if sa > 0 and sb > 0 and sa ~= sb then
            return sa < sb
        end
        return (a.title or a.vol_name or "") < (b.title or b.vol_name or "")
    end)
    return vols
end

-- 选"开始阅读"时：找最适合打开的卷
-- 优先级：
--   1) 有本地进度（LOCAL_VOL_INDEX[fmd]._local_last_read > 0）且已下载 → 最近被阅读过的卷
--   2) 没有本地进度 → time_update 最大（最新更新）且已下载的卷
--   3) 所有卷都没下载 → 返回 time_update 最大的卷（由 UI 提示用户先下载）
function Bookshelf:get_latest_readable_vol(series_id)
    local vols = self:get_series_vols(series_id)
    if not vols or #vols == 0 then return nil end
    -- 1) 最近被本地阅读过的卷
    local latest_vol = nil
    local latest_time = 0
    for _, v in ipairs(vols) do
        local fmd = tostring(v.file_md5 or v.fmd or "")
        local info = LOCAL_VOL_INDEX[fmd]
        local local_lr = info and tonumber(info._local_last_read) or 0
        local dl = self:is_vol_downloaded(v)
        if local_lr > 0 and dl and local_lr > latest_time then
            latest_time = local_lr
            latest_vol = v
        end
    end
    if latest_vol then return latest_vol, "local" end
    -- 2) time_update 最大且已下载的
    local best_update = 0
    local best_downloaded = nil
    local best_any = nil
    local best_all_update = 0
    for _, v in ipairs(vols) do
        local upd = tonumber(v.update_time or v.last_update_time or v.update_time or 0) or 0
        local dl = self:is_vol_downloaded(v)
        if dl and upd > best_update then
            best_update = upd
            best_downloaded = v
        end
        if upd > best_all_update then
            best_all_update = upd
            best_any = v
        end
    end
    if best_downloaded then return best_downloaded, "downloaded" end
    return best_any, "none"
end

-- 获取卷的本地进度信息（shelf_view 显示用，避免直接暴露 LOCAL_VOL_INDEX 内部 upvalue）
function Bookshelf:get_vol_progress_info(fmd)
    fmd = tostring(fmd or "")
    if fmd == "" then return nil end
    local info = LOCAL_VOL_INDEX[fmd]
    if not info then return nil end
    return {
        last_readpage = tonumber(info.last_readpage) or 0,
        total_pages = tonumber(info.total_pages) or 0,
        _local_last_read = tonumber(info._local_last_read) or 0,
        series_id = info.series_id,
    }
end

-- 作废指定系列的所有缓存（用户点"刷新系列"时调用，强制下次重拉 API）
function Bookshelf:invalidate_series_cache(sid)
    sid = tostring(sid or "")
    if sid == "" then return end
    -- 内存
    SERIES_VOLS_MEM[sid] = nil
    -- state.directory_cache：清理该系列所有 sort 的缓存
    if state and state.invalidateDirectoryCache then
        pcall(function()
            state.invalidateDirectoryCache(sid)
        end)
    end
    -- client L1 短缓存：如果 sid 跟真实 api_sid 一致就清
    if self.client and self.client.clearVolListCache then
        pcall(function() self.client:clearVolListCache(sid) end)
    end
    -- 系列文件缓存：删除整份 shelf_cache（下次 load 时重拉）
    local function _has_sid()
        if not SERIES_MEM_CACHE then return false end
        for _, s in ipairs(SERIES_MEM_CACHE) do
            if tostring(s.id or "") == sid then return true end
        end
        return false
    end
    if _has_sid() and self.shelf_cache_file and H.file_exists(self.shelf_cache_file) then
        os.remove(self.shelf_cache_file)
    end
end

function Bookshelf:sort_vols(sort_key)
    sort_key = sort_key or "uptime"
    self.settings:set_shelf_sort(sort_key)
    if self.settings and self.settings.flush then pcall(function() self.settings:flush() end) end
    self.dirty = true
    -- 修复：不再清空 SERIES_VOLS_MEM + state.directory_cache
    -- 因为现在缓存保存的是 UNSORTED 原始数据，排序是在 get_series_vols return 前
    -- 对 shallow_copy 副本做的，切 sort 完全不影响缓存有效性 → 避免切 sort 后目录全 miss 重新打 API
end

-- ------- 兼容旧调用方的辅助方法 -------
function Bookshelf:get_vols()
    -- 废弃：不再有"全局 vols"。如需某系列的 vols，用 get_series_vols(series_id)
    Log.debug("Bookshelf:get_vols 已废弃，返回空")
    return self.vols or {}
end

function Bookshelf:get_count()
    local series = self:ensure_loaded()
    return #series
end

function Bookshelf:get_vol_by_fmd(fmd)
    if not fmd then return nil end
    local target = tostring(fmd)
    -- 1. 在已缓存的系列 vols 里找（避免 HTTP 请求）
    for _, cache in pairs(SERIES_VOLS_MEM) do
        if cache and cache.vols then
            for _, v in ipairs(cache.vols) do
                if tostring(v.file_md5 or v.fmd or "") == target then
                    return v
                end
            end
        end
    end
    -- 2. LOCAL_VOL_INDEX 里有 sid → 用 sid 调 get_series_vols 重新加载完整 vol
    --    （重启后 SERIES_VOLS_MEM 为空，但进度索引里有 sid，可借此恢复）
    local info = LOCAL_VOL_INDEX[target]
    if info and info.series_id and info.series_id ~= "" then
        local sid = tostring(info.series_id)
        local vols = self:get_series_vols(sid)
        if vols then
            for _, v in ipairs(vols) do
                if tostring(v.file_md5 or v.fmd or "") == target then
                    return v
                end
            end
        end
    end
    -- 3. 最后兜底：从 LOCAL_VOL_INDEX 拿进度元信息（不完整，缺 file_url 等）
    if info then
        local ret = {}
        for k, v in pairs(info) do ret[k] = v end
        ret.file_md5 = target
        ret.fmd = target
        return ret
    end
    return nil
end

function Bookshelf:_rebuild_series_map()
    -- 已废弃（不需要从全局 vols 派生系列 map）
end

-- ============================================================
-- 封面（同步阻塞下载，UI层应使用异步批量调用 download_covers）
-- ============================================================

-- 封面下载：禁用 SSL 验证 + 正确 Referer + cookie
-- H.download_file 不禁用 SSL 验证且 Referer 用图片域名，在 Kindle 上会失败
-- 此方法与 http_downloader.lua 的 SSL bypass 策略一致
function Bookshelf:download_cover_file(cover_url, save_path)
    -- fanqie 同款：client.get_binary 拿到二进制字符串 + io.open/write/close
    if not cover_url or cover_url == "" then
        return false, "cover_url 为空"
    end
    local ok_call, ret1, ret2 = pcall(function()
        return self.client:get_binary(cover_url, { timeout = 30 })
    end)
    if not ok_call then
        return false, "get_binary 异常: " .. tostring(ret1)  -- ret1 是错误信息
    end
    local data = ret1
    local code_or_err = ret2
    if not data or #data == 0 then
        return false, "get_binary 返回空数据"
    end
    local dir = save_path:match("^(.*)[/\\][^/\\]*$")
    if dir and dir ~= "" then
        H.make_dir(dir)
    end
    local file, err_open = io.open(save_path, "wb")
    if not file then
        return false, "无法打开文件: " .. tostring(err_open or save_path)
    end
    file:write(data)
    file:close()
    local lfs = require("libs/libkoreader-lfs")
    local attr_ok, attr = pcall(function() return lfs.attributes(save_path) end)
    if not attr_ok or not attr or not attr.size or attr.size == 0 then
        pcall(os.remove, save_path)
        return false, "写入后文件为空"
    end
    return true, tostring(code_or_err or "")
end

function Bookshelf:get_cover_local_path(vol)
    if not vol then return nil end
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return nil end
    if self.covers[fmd] then
        return self.covers[fmd]
    end
    local covers_dir = H.get_covers_dir()
    H.make_dir(covers_dir)
    local filename = fmd .. ".jpg"
    local cover_path = H.join_path(covers_dir, filename)
    if H.file_exists(cover_path) then
        local lfs = require("libs/libkoreader-lfs")
        local ok, attr = pcall(function()
            return lfs.attributes(cover_path)
        end)
        if ok and attr and attr.size and attr.size > 0 then
            self.covers[fmd] = cover_path
            return cover_path
        else
            os.remove(cover_path)
        end
    end
    if not self.settings:should_download_covers() then
        return nil
    end
    local cover_url = vol.cover_url
    if not cover_url or cover_url == "" then
        return nil
    end
    local ok, err = self:download_cover_file(cover_url, cover_path)
    if ok then
        self.covers[fmd] = cover_path
        return cover_path
    else
        Log.warn("下载封面失败:", fmd, err)
    end
    return nil
end

-- 批量静默下载封面（异步调用，不阻塞UI）
-- 下载成功后写回 vol.cover_path，内存缓存共享引用，下次刷新自动生效
function Bookshelf:download_covers(vols)
    -- fanqie 同款：for 循环 client:get_binary 拿二进制，io.open+write 写文件
    -- （调用方负责放在异步/逐个 yield 的场景里，避免单次调用太久）
    if not vols or #vols == 0 then return end
    if not self.settings or not self.settings.should_download_covers or not self.settings:should_download_covers() then return end
    local covers_dir = H.get_covers_dir()
    H.make_dir(covers_dir)
    local count = 0
    for _, vol in ipairs(vols) do
        if not vol.cover_path then
            local fmd = tostring(vol.file_md5 or vol.fmd or "")
            if fmd ~= "" and vol.cover_url and vol.cover_url ~= "" then
                local cover_path = H.join_path(covers_dir, fmd .. ".jpg")
                if not H.file_exists(cover_path) then
                    local ok_dl, err_dl = pcall(function()
                        local data = self.client:get_binary(vol.cover_url, { timeout = 30 })
                        local f = io.open(cover_path, "wb")
                        if f then
                            f:write(data)
                            f:close()
                            vol.cover_path = cover_path
                            self.covers[fmd] = cover_path
                            return true
                        end
                        return false
                    end)
                    if ok_dl and err_dl == true then
                        count = count + 1
                    else
                        Log.warn("[Koobone] download_covers 失败 fmd=" .. fmd .. ": " .. tostring(err_dl or ""))
                    end
                else
                    vol.cover_path = cover_path
                    self.covers[fmd] = cover_path
                end
            end
        end
    end
    if count > 0 then
        Log.info("Bookshelf:download_covers 成功下载", count, "个封面")
    end
end

function Bookshelf:get_progress_text(vol)
    if not vol then return "未开始" end
    local last_readpage = tonumber(vol.last_readpage) or 0
    local total_pages = tonumber(vol.total_pages) or 0
    if total_pages <= 0 then
        return "未开始"
    end
    if last_readpage <= 0 then
        return "未开始"
    end
    if last_readpage >= total_pages then
        return "已读完"
    end
    return string.format("%d/%d页", last_readpage, total_pages)
end

function Bookshelf:_save_shelf_cache()
    -- 对外的 save 接口：持久化当前 SERIES_MEM_CACHE（书架）+ 本地进度索引
    return save_shelf_cache(self, SERIES_MEM_CACHE or {})
end

-- 更新 LOCAL_VOL_INDEX 并按需写回持久化
local function _flush_pending_if_needed(self)
    self._pending_changes = (self._pending_changes or 0) + 1
    local now = os.time()
    local elapsed = now - (self._last_save_ts or 0)
    if self._pending_changes >= 10 or elapsed >= 30 then
        save_shelf_cache(self, SERIES_MEM_CACHE or {})
    end
end

function Bookshelf:save_vol_progress(fmd, page_index, total_pages, last_read_ts)
    if not fmd then return end
    fmd = tostring(fmd)
    page_index = tonumber(page_index) or 0
    total_pages = tonumber(total_pages) or 0
    local changed = false

    -- 写 LOCAL_VOL_INDEX（持久化来源）
    local info = LOCAL_VOL_INDEX[fmd]
    if not info then
        info = { fmd = fmd }
        LOCAL_VOL_INDEX[fmd] = info
    end
    local old_page = tonumber(info.last_readpage) or 0
    local old_total = tonumber(info.total_pages) or 0
    if page_index > old_page then
        info.last_readpage = page_index
        changed = true
    end
    if total_pages > 0 and total_pages > old_total then
        info.total_pages = total_pages
        changed = true
    end
    if last_read_ts then
        info._local_last_read = tonumber(last_read_ts) or os.time()
        changed = true
    end

    -- 如果 vol 对象正好在内存缓存（SERIES_VOLS_MEM）里，同步更新
    for _, cache in pairs(SERIES_VOLS_MEM) do
        if cache and cache.vols then
            for _, v in ipairs(cache.vols) do
                if tostring(v.file_md5 or v.fmd or "") == fmd then
                    if info.last_readpage then v.last_readpage = info.last_readpage end
                    if info.total_pages then v.total_pages = info.total_pages end
                    if info._local_last_read then v._local_last_read = info._local_last_read end
                    break
                end
            end
        end
    end

    if changed then
        -- 更新系列级 last_read（更新对应系列的 _local_last_read）
        -- 这样系列列表按"最后阅读"排序时能正确生效
        -- 从内存缓存的 SERIES_VOLS_MEM 中反查 series_id
        local found_sid = nil
        for sid, cache in pairs(SERIES_VOLS_MEM) do
            if cache and cache.vols then
                for _, v in ipairs(cache.vols) do
                    if tostring(v.file_md5 or v.fmd or "") == fmd then
                        found_sid = sid
                        break
                    end
                end
            end
            if found_sid then break end
        end
        if found_sid then
            -- 记录 sid 到卷级索引，重启后 get_vol_by_fmd 可用它重新加载完整 vol
            info.series_id = found_sid
            if SERIES_MEM_CACHE then
                for _, s in ipairs(SERIES_MEM_CACHE) do
                    if tostring(s.id or "") == found_sid then
                        s._local_last_read = info._local_last_read or os.time()
                        LOCAL_VOL_INDEX["series:" .. found_sid] = {
                            _local_last_read = s._local_last_read,
                        }
                        break
                    end
                end
            end
        end
        _flush_pending_if_needed(self)
    end
end

function Bookshelf:touch_vol_read_time(fmd)
    if not fmd then return end
    fmd = tostring(fmd)
    local now_ts = os.time()

    -- 更新 LOCAL_VOL_INDEX
    local info = LOCAL_VOL_INDEX[fmd]
    if not info then
        info = { fmd = fmd }
        LOCAL_VOL_INDEX[fmd] = info
    end
    info._local_last_read = now_ts

    -- 同步更新 SERIES_VOLS_MEM 里的 vol 对象
    local found_sid = nil
    for sid, cache in pairs(SERIES_VOLS_MEM) do
        if cache and cache.vols then
            for _, v in ipairs(cache.vols) do
                if tostring(v.file_md5 or v.fmd or "") == fmd then
                    v._local_last_read = now_ts
                    found_sid = sid
                    break
                end
            end
        end
        if found_sid then break end
    end

    -- 同步更新系列级 _local_last_read
    if found_sid then
        info.series_id = found_sid
        if SERIES_MEM_CACHE then
            for _, s in ipairs(SERIES_MEM_CACHE) do
                if tostring(s.id or "") == found_sid then
                    s._local_last_read = now_ts
                    LOCAL_VOL_INDEX["series:" .. found_sid] = {
                        _local_last_read = now_ts,
                    }
                    break
                end
            end
        end
    end
    _flush_pending_if_needed(self)
end

function Bookshelf:is_vol_downloaded(vol)
    if not vol then return false end
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return false end
    local epub_dir = H.get_epub_dir()

    local series_key = vol.series_id or vol.series or nil
    if not series_key or series_key == "" then
        series_key = "__fmd__:" .. fmd
    end
    local downloaded_map = state.getDownloadedChapters(series_key)

    if downloaded_map and downloaded_map[fmd] ~= nil then
        return downloaded_map[fmd] == true or downloaded_map[fmd] == 1
    end

    local function check_one(target_fmd, file_md5_override)
        local real_fmd = target_fmd or ""
        if real_fmd == "" then return false end
        local epub_name = (file_md5_override and tostring(file_md5_override) or real_fmd) .. ".epub"
        local epub_path = H.join_path(epub_dir, epub_name)
        if not H.file_exists(epub_path) then return false end
        local sz = H.file_size and H.file_size(epub_path) or 0
        return sz and sz > 1024
    end

    local current_result = check_one(fmd, vol.file_md5)

    if downloaded_map then
        downloaded_map[fmd] = current_result and true or false
        state.setDownloadedChapters(series_key, downloaded_map)
    else
        local new_map = {}
        new_map[fmd] = current_result and true or false
        -- 从 SERIES_VOLS_MEM 缓存里拿同系列 vols（有就批量预查，没有就算了，下次进来自然会查到）
        local sk_str = tostring(series_key)
        if not sk_str:find("^__fmd__:") then
            local cache = SERIES_VOLS_MEM[sk_str]
            if cache and cache.vols then
                for _, v in ipairs(cache.vols) do
                    local vfmd = tostring(v.file_md5 or v.fmd or "")
                    if vfmd ~= "" and new_map[vfmd] == nil then
                        new_map[vfmd] = check_one(vfmd, v.file_md5) and true or false
                    end
                end
            end
        end
        state.setDownloadedChapters(series_key, new_map)
    end
    return current_result
end

-- 主动标记某卷的下载状态（下载成功/删除时调用，直接更新缓存避免下次重新查文件）
function Bookshelf:markVolDownloaded(vol, flag)
    if not vol then return end
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return end
    local series_key = vol.series_id or vol.series or nil
    if not series_key or series_key == "" then
        series_key = "__fmd__:" .. fmd
    end
    local map = state.getDownloadedChapters(series_key)
    if not map then map = {} end
    map[fmd] = flag and true or false
    state.setDownloadedChapters(series_key, map)
    Log.debug("markVolDownloaded: fmd=", fmd, "flag=", flag, "series=", series_key)
end

return Bookshelf
