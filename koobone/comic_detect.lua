-- Koobone 通用漫画识别器
-- 通过扫描 EPUB ZIP 中心目录(不解压)统计图片占比,判断是否为漫画。
-- 算法复用 MangaFit 的 static_scan_epub_archive(mangafit.koplugin/main.lua L1862)。
-- 识别结果用于:comic → 路由到 MuPDF 分页模式(或让 MangaFit 接管);
--              text → 保持 CREngine + CSS 铺满。

local ok_Archiver, Archiver = pcall(require, "ffi/archiver")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_util, util = pcall(require, "util")
local ok_Log, Log = pcall(require, "koobone.logger")
local Log = ok_Log and Log or { debug = function() end, warn = function() end, error = function() end }

local M = {}

-- 复用 MangaFit 的扩展名分类(mangafit.koplugin/main.lua L144-151)
local IMAGE_EXT = {
    jpg = true, jpeg = true, png = true, webp = true, gif = true, bmp = true,
    jp2 = true, j2k = true, jpf = true, tif = true, tiff = true, avif = true, svg = true,
}
local MARKUP_EXT = {
    xhtml = true, html = true, htm = true, xml = true, css = true, ncx = true, opf = true,
}
local FONT_EXT = { ttf = true, otf = true, woff = true, woff2 = true }

-- 限制扫描条目数,防止超大 ZIP 卡 UI(与 MangaFit PREOPEN_MAX_ENTRIES 一致)
local MAX_ENTRIES = 12000
-- 小文件不值得扫描,直接判 text(< 1MB 的 EPUB 几乎不可能是漫画)
local MIN_SCAN_SIZE = 1024 * 1024

-- 获取文件扩展名(小写)
local function get_extension(path)
    if type(path) ~= "string" then return "" end
    return (path:lower():match("%.([%w]+)$") or "")
end
M.get_extension = get_extension

-- 扫描 EPUB ZIP 中心目录,统计图片/正文/字体占比
-- 返回 "comic" / "text" / nil,以及描述信息
function M.scan(file)
    if not file or file == "" then return nil, "空路径" end
    if not ok_Archiver or not Archiver then return nil, "Archiver 不可用" end

    -- 小文件直接判 text
    local size = ok_lfs and lfs.attributes(file, "size") or 0
    if size < MIN_SCAN_SIZE then
        return "text", "文件过小(<1MB),跳过扫描"
    end

    local ext = get_extension(file)
    if ext ~= "epub" and ext ~= "epub3" and ext ~= "zip" then
        return nil, "非 EPUB/ZIP 格式: " .. ext
    end

    local arc = Archiver.Reader:new()
    if not arc:open(file) then
        return nil, "无法读取 EPUB ZIP 目录"
    end

    local stats = {
        entries = 0,
        image_count = 0,
        image_bytes = 0,
        markup_count = 0,
        markup_bytes = 0,
        font_bytes = 0,
        other_bytes = 0,
    }

    local ok_iter, err = pcall(function()
        for entry in arc:iterate() do
            stats.entries = stats.entries + 1
            if stats.entries > MAX_ENTRIES then
                break
            end
            if entry.mode == "file" then
                local entry_size = tonumber(entry.size) or 0
                local entry_ext = ""
                if ok_util and util.getFileNameSuffix then
                    entry_ext = util.getFileNameSuffix(entry.path or "") or ""
                else
                    entry_ext = (entry.path or ""):lower():match("%.([%w]+)$") or ""
                end
                entry_ext = entry_ext:lower()
                if IMAGE_EXT[entry_ext] then
                    stats.image_count = stats.image_count + 1
                    stats.image_bytes = stats.image_bytes + entry_size
                elseif MARKUP_EXT[entry_ext] then
                    stats.markup_count = stats.markup_count + 1
                    stats.markup_bytes = stats.markup_bytes + entry_size
                elseif FONT_EXT[entry_ext] then
                    stats.font_bytes = stats.font_bytes + entry_size
                else
                    stats.other_bytes = stats.other_bytes + entry_size
                end
            end
        end
    end)
    arc:close()
    if not ok_iter then
        return nil, "扫描异常: " .. tostring(err)
    end

    local payload = stats.image_bytes + stats.markup_bytes + stats.font_bytes + stats.other_bytes
    local image_ratio = payload > 0 and (stats.image_bytes / payload) or 0
    local avg_image = stats.image_count > 0 and (stats.image_bytes / stats.image_count) or 0

    -- 漫画识别阈值(直接复用 MangaFit 的三档判定)
    local comic = false
    if stats.image_count >= 12 and stats.image_bytes >= 8 * 1024 * 1024 and image_ratio >= 0.78 then
        comic = true
    elseif stats.image_count >= 24 and avg_image >= 96 * 1024
        and image_ratio >= 0.66 and stats.markup_bytes <= stats.image_bytes * 0.10 then
        comic = true
    elseif stats.image_count >= 40 and stats.image_bytes >= 20 * 1024 * 1024
        and image_ratio >= 0.60 and avg_image >= 80 * 1024 then
        comic = true
    end

    -- 文字书识别阈值
    local text = false
    if stats.markup_count >= 6 and stats.image_count <= 8 then
        text = true
    elseif stats.markup_count >= 8 and stats.markup_bytes >= 96 * 1024 and image_ratio < 0.42 then
        text = true
    end

    local info = string.format(
        "Koobone 识别:图片 %d 项/%.1fMB 占载荷 %.0f%%;正文标记 %d 项/%.1fMB;扫描 %d 条目",
        stats.image_count, stats.image_bytes / 1024 / 1024, image_ratio * 100,
        stats.markup_count, stats.markup_bytes / 1024 / 1024,
        stats.entries
    )
    Log.debug("[KooboneDetect] " .. info)

    if comic then return "comic", info end
    if text then return "text", info end
    return nil, info
end

-- 查找 KOReader 官方 MuPDF provider(复用 MangaFit 的 static_find_mupdf_provider 算法)
function M.find_mupdf_provider(file)
    local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
    if not ok_dr or not DocumentRegistry then return nil end
    local ok, providers = pcall(DocumentRegistry.getProviders, DocumentRegistry, file)
    if not ok or not providers then return nil end
    for _, record in ipairs(providers) do
        if record.provider and record.provider.provider == "mupdf" then
            return record.provider
        end
    end
    return nil
end

-- 检测 MangaFit 是否已安装并 patch 了 showReader
function M.has_mangafit()
    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_rui or not ReaderUI then return false end
    return ReaderUI._mangafit_native_epub_v21 == true
end

return M
