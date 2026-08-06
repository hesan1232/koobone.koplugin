-- Koobone 补丁
-- 1. 打开 koobone 漫画时自动注入"图片高度优先（铺满）"CSS
--    通过设置 ReaderStyleTweak.book_style_tweak 和 book_style_tweak_enabled
-- 2. 在 styletweaks 目录创建 CSS 文件供用户手动使用
-- 3. koobone 缓存文件不进入阅读历史

local M = {
    _mark = "_koobone_patch",
}

local H = require("koobone.helper")

-- 检查插件是否被禁用
M.is_plugin_disabled = function()
    if G_reader_settings and G_reader_settings.readSetting then
        local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
        if plugins_disabled and plugins_disabled["koobone"] == true then
            return true
        end
    end
    return false
end

-- 判断是否为 koobone 下载的漫画文件路径
local is_koobone_path = function(file_path)
    if not H.is_str(file_path) then return false end
    return file_path:lower():find("koobone", 1, true) ~= nil
end

-- 图片高度优先（铺满）的 CSS
local IMAGE_FILL_HEIGHT_CSS = [[
/* Koobone: 图片高度优先，尽量铺满 */
img, svg {
    height: 100vh !important;
    width: auto !important;
    max-width: 100% !important;
    object-fit: contain !important;
    margin: 0 auto !important;
    display: block !important;
}
body {
    margin: 0 !important;
    padding: 0 !important;
}
]]

-- 补丁：ReaderUI — 当打开 koobone 漫画时自动设置样式调整
local function patchReaderUI()
    local ok_ReaderUI, ReaderUI = pcall(require, "apps/reader/readerui")
    if not ok_ReaderUI or not ReaderUI then return end

    -- 保存原始的 showReader 方法
    if not ReaderUI._koobone_original_showReader then
        ReaderUI._koobone_original_showReader = ReaderUI.showReader
        ReaderUI.showReader = function(self, file)
            -- 调用原始方法
            local result = ReaderUI._koobone_original_showReader(self, file)

            -- 如果是 koobone 漫画，自动设置样式调整
            if is_koobone_path(file) then
                local UIManager = require("ui/uimanager")
                -- 等待 ReaderUI 和 styletweak 初始化完成
                UIManager:scheduleIn(2.0, function()
                    local ui = self
                    if ui and ui.styletweak then
                        local st = ui.styletweak
                        -- 设置书籍样式调整
                        st.book_style_tweak = IMAGE_FILL_HEIGHT_CSS
                        st.book_style_tweak_enabled = true
                        st.enabled = true
                        -- 保存配置
                        if ui.document and ui.document.configurable then
                            pcall(function()
                                ui.document.configurable.book_style_tweak = IMAGE_FILL_HEIGHT_CSS
                                ui.document.configurable.book_style_tweak_enabled = true
                            end)
                        end
                        -- 更新 CSS 文本并应用
                        st:updateCssText(true)
                    end
                end)
            end

            return result
        end
    end
end

-- 安装补丁
M.install = function()
    if M.is_plugin_disabled() then
        return
    end

    -- =========================================================================
    -- 补丁1：自动注入"图片高度优先（铺满）"CSS
    -- =========================================================================
    patchReaderUI()

    -- =========================================================================
    -- 补丁2：在 styletweaks 目录创建 CSS 文件（供用户手动使用）
    -- =========================================================================
    local ok_DataStorage, DataStorage = pcall(require, "datastorage")
    if ok_DataStorage and DataStorage then
        local styletweaks_dir = DataStorage:getDataDir() .. "/styletweaks"
        H.make_dir(styletweaks_dir)
        local css_file = styletweaks_dir .. "/图片高度优先_铺满.css"
        -- 如果文件不存在则创建（避免覆盖用户修改）
        if not H.file_exists(css_file) then
            local f = io.open(css_file, "w")
            if f then
                f:write(IMAGE_FILL_HEIGHT_CSS)
                f:close()
            end
        end
    end

    -- =========================================================================
    -- 补丁3：ReadHistory — koobone 缓存文件不进入阅读历史
    -- =========================================================================
    local ok_ReadHistory, ReadHistory = pcall(require, "readhistory")
    if ok_ReadHistory and ReadHistory and not ReadHistory[M._mark] then
        local original_addItem = ReadHistory.addItem
        function ReadHistory:addItem(file, ts, no_flush)
            if is_koobone_path(file) then
                return
            end
            return original_addItem(self, file, ts, no_flush)
        end
        ReadHistory[M._mark] = true
    end
end

return M
