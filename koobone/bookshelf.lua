local H = require("koobone.helper")
local Log = require("koobone.logger")
local state = require("koobone.state")

local Bookshelf = {}
Bookshelf.__index = Bookshelf

function Bookshelf:new(settings, client)
    local obj = {
        settings = settings,
        client = client,
        vols = {},
        series_map = {},
        covers = {},
        dirty = true,
        shelf_cache_file = H.get_data_dir() .. "/shelf_cache.json",
        _last_save_ts = 0,
        _pending_changes = 0,
    }
    H.make_dir(H.get_data_dir())
    return setmetatable(obj, self)
end

function Bookshelf:refresh(force)
    Log.debug("Bookshelf:refresh force=", force)
    if not force and state.isShelfCacheValid() then
        local cached = state.getShelfVols()
        if cached and #cached > 0 then
            self.vols = cached
            self.dirty = true
            Log.info("Bookshelf:refresh 使用 state 内存缓存, 共", #self.vols, "卷")
            return self.vols, nil
        end
    end

    local sort_key = self.settings:get_shelf_sort()
    local ok, vols_or_err = pcall(function()
        return self.client:get_vol_list({ sort = sort_key })
    end)

    if not ok then
        local err = tostring(vols_or_err)
        Log.error("Bookshelf:refresh 拉取失败:", err)
        return nil, err
    end

    local vols = vols_or_err or {}
    self.vols = vols
    self.dirty = true
    state.setShelfVols(vols)
    self:_save_shelf_cache()
    Log.info("Bookshelf:refresh 完成, 共", #self.vols, "卷")
    return self.vols, nil
end

function Bookshelf:load_local_cache()
    Log.debug("Bookshelf:load_local_cache")
    if not H.file_exists(self.shelf_cache_file) then
        Log.info("书架缓存文件不存在")
        return {}
    end
    local file = io.open(self.shelf_cache_file, "r")
    if not file then
        Log.warn("书架缓存文件无法打开")
        return {}
    end
    local content = file:read("*all")
    file:close()
    local data = H.json_decode(content)
    if not data or not data.vols then
        Log.warn("书架缓存 JSON 解析失败或缺少 vols 字段")
        return {}
    end
    self.vols = data.vols
    self.dirty = true
    Log.info("加载书架缓存:", #self.vols, "卷")
    return self.vols
end

function Bookshelf:ensure_loaded()
    if self.vols and #self.vols > 0 then
        return self.vols
    end
    self:load_local_cache()
    if self.vols and #self.vols > 0 then
        return self.vols
    end
    local ok, err = self:refresh(false)
    if ok then
        return ok
    end
    return self.vols or {}
end

function Bookshelf:get_vols()
    self:ensure_loaded()
    return self.vols or {}
end

function Bookshelf:get_count()
    self:ensure_loaded()
    return #(self.vols or {})
end

function Bookshelf:get_vol_by_fmd(fmd)
    if not fmd then return nil end
    self:ensure_loaded()
    local target = tostring(fmd)
    for _, vol in ipairs(self.vols or {}) do
        if tostring(vol.file_md5 or vol.fmd or "") == target then
            return vol
        end
    end
    return nil
end

function Bookshelf:_rebuild_series_map()
    if not self.dirty then
        return
    end
    self.series_map = {}
    local order = {}
    for _, vol in ipairs(self.vols or {}) do
        local sid = vol.series_id or vol.series or ""
        if sid ~= "" then
            if not self.series_map[sid] then
                self.series_map[sid] = {}
                table.insert(order, sid)
            end
            table.insert(self.series_map[sid], vol)
        end
    end
    self._series_order = order
    self.dirty = false
end

function Bookshelf:get_series_list()
    self:ensure_loaded()
    self:_rebuild_series_map()
    local result = {}
    for _, sid in ipairs(self._series_order or {}) do
        local vols = self.series_map[sid]
        if vols and #vols > 0 then
            local last_update = 0
            local cover_url = ""
            local author = ""
            local title = ""
            for _, v in ipairs(vols) do
                if v.update_time > last_update then
                    last_update = v.update_time
                end
                if cover_url == "" and v.cover_url then
                    cover_url = v.cover_url
                end
                if author == "" and v.author then
                    author = v.author
                end
                if title == "" and v.series then
                    title = v.series
                end
            end
            if title == "" then
                title = vols[1].title or ""
            end
            if cover_url == "" then
                cover_url = vols[1].cover_url or ""
            end
            if author == "" then
                author = vols[1].author or ""
            end
            table.insert(result, {
                id = sid,
                title = title,
                author = author,
                cover_url = cover_url,
                vol_count = #vols,
                last_update_time = last_update,
                vols = vols,
            })
        end
    end
    table.sort(result, function(a, b)
        return (a.last_update_time or 0) > (b.last_update_time or 0)
    end)
    return result
end

function Bookshelf:get_series_vols(series_id)
    if not series_id then
        return {}
    end
    self:ensure_loaded()
    self:_rebuild_series_map()
    local vols = self.series_map[series_id]
    if not vols or #vols == 0 then
        vols = {}
        local sid = tostring(series_id)
        for _, vol in ipairs(self.vols or {}) do
            local vsid = vol.series_id or vol.series or ""
            if vsid == sid then
                table.insert(vols, vol)
            end
        end
    end
    table.sort(vols, function(a, b)
        local sa = a.vol_snumber or 0
        local sb = b.vol_snumber or 0
        if sa ~= sb and sa > 0 and sb > 0 then
            return sa < sb
        end
        return (a.update_time or 0) < (b.update_time or 0)
    end)
    return vols
end

function Bookshelf:sort_vols(sort_key)
    sort_key = sort_key or "uptime"
    self:ensure_loaded()
    if sort_key == "uptime" then
        table.sort(self.vols, function(a, b)
            return (a.update_time or 0) > (b.update_time or 0)
        end)
    elseif sort_key == "vol_name" then
        table.sort(self.vols, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    elseif sort_key == "last_read" then
        table.sort(self.vols, function(a, b)
            local ta = a._local_last_read or 0
            local tb = b._local_last_read or 0
            return ta > tb
        end)
    end
    self.settings:set_shelf_sort(sort_key)
    self.settings:flush()
    self.dirty = true
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
    local ok, err = H.download_file(cover_url, cover_path)
    if ok then
        local lfs = require("libs/libkoreader-lfs")
        local attr_ok, attr = pcall(function()
            return lfs.attributes(cover_path)
        end)
        if attr_ok and attr and attr.size and attr.size > 0 then
            self.covers[fmd] = cover_path
            return cover_path
        else
            os.remove(cover_path)
        end
    else
        Log.warn("下载封面失败:", fmd, err)
    end
    return nil
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
    local vols = self.vols or {}
    if #vols == 0 and H.file_exists(self.shelf_cache_file) then
        Log.warn("save_shelf_cache: vols 为空但缓存已存在，跳过防止覆盖")
        return false
    end
    local cache_data = {
        vols = vols,
        saved_at = os.time(),
    }
    local json_data = H.json_encode(cache_data)
    if not json_data then
        return false
    end
    local tmp_path = self.shelf_cache_file .. ".tmp"
    local file = io.open(tmp_path, "w")
    if not file then
        return false
    end
    file:write(json_data)
    file:close()
    local ok, err = os.rename(tmp_path, self.shelf_cache_file)
    if ok then
        Log.debug("书架缓存已写入, ", #vols, "卷")
        self._last_save_ts = os.time()
        self._pending_changes = 0
        return true
    else
        Log.error("书架缓存原子重命名失败:", tostring(err))
        os.remove(tmp_path)
        return false
    end
end

function Bookshelf:save_vol_progress(fmd, page_index, total_pages, last_read_ts)
    if not fmd then return end
    local vol = self:get_vol_by_fmd(fmd)
    if not vol then return end
    local changed = false
    page_index = tonumber(page_index) or 0
    total_pages = tonumber(total_pages) or 0
    local old_page = tonumber(vol.last_readpage) or 0
    local old_total = tonumber(vol.total_pages) or 0
    if page_index > old_page then
        vol.last_readpage = page_index
        changed = true
    end
    if total_pages > 0 and total_pages > old_total then
        vol.total_pages = total_pages
        changed = true
    end
    if last_read_ts then
        vol._local_last_read = tonumber(last_read_ts) or os.time()
        changed = true
    end
    if changed then
        self._pending_changes = (self._pending_changes or 0) + 1
        local now = os.time()
        local elapsed = now - (self._last_save_ts or 0)
        if self._pending_changes >= 10 or elapsed >= 30 then
            self:_save_shelf_cache()
        end
    end
end

function Bookshelf:touch_vol_read_time(fmd)
    if not fmd then return end
    local vol = self:get_vol_by_fmd(fmd)
    if vol then
        vol._local_last_read = os.time()
        self._pending_changes = (self._pending_changes or 0) + 1
        local now = os.time()
        local elapsed = now - (self._last_save_ts or 0)
        if self._pending_changes >= 10 or elapsed >= 30 then
            self:_save_shelf_cache()
        end
    end
end

function Bookshelf:is_vol_downloaded(vol)
    if not vol then return false end
    local fmd = tostring(vol.file_md5 or vol.fmd or "")
    if fmd == "" then return false end

    -- 检查 EPUB 文件是否存在（不再需要解压后的 _pages.json）
    local epub_dir = H.get_epub_dir()
    local file_md5 = vol.file_md5 or fmd
    local epub_path = H.join_path(epub_dir, tostring(file_md5) .. ".epub")

    if H.file_exists(epub_path) then
        -- 简单检查文件大小是否有效（至少 1KB）
        local size = H.file_size and H.file_size(epub_path) or 0
        if size and size > 1024 then
            return true
        end
    end

    return false
end

return Bookshelf
