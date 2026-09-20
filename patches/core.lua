-- Koobone 补丁
-- 1. 打开 koobone 漫画时自动注入"图片高度优先（铺满）"CSS
--    通过设置 ReaderStyleTweak.book_style_tweak 和 book_style_tweak_enabled
-- 2. 在 styletweaks 目录创建 CSS 文件供用户手动使用
-- 3. koobone 缓存文件不进入阅读历史

local M = {
    _mark = "_koobone_patch",
}

local H = require("koobone.helper")
local comic_detect = require("koobone.comic_detect")

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
        ReaderUI.showReader = function(self, file, ...)
            -- 解析 vararg:provider / seamless / is_provider_forced / after_open_callback
            local provider, seamless, is_provider_forced, after_open_callback = ...

            -- 如果 provider 已被其他插件强制（如 MangaFit），尊重它，直接透传
            if is_provider_forced then
                return ReaderUI._koobone_original_showReader(self, file, ...)
            end

            -- 前处理：通用漫画识别（仅对 EPUB 且 provider 未强制时）
            local ext = comic_detect.get_extension(file)
            local is_epub = ext == "epub" or ext == "epub3"
            local has_mangafit = comic_detect.has_mangafit()
            local comic_detected = false

            if is_epub then
                if is_koobone_path(file) then
                    -- Koobone 下载的必定是漫画
                    comic_detected = true
                else
                    -- 通用识别：扫描 ZIP 中心目录统计图片占比
                    local class = comic_detect.scan(file)
                    comic_detected = (class == "comic")
                end
            end

            if comic_detected then
                if has_mangafit then
                    -- 有 MangaFit：透传，让 MangaFit 接管识别 + provider 选择 + 裁边
                    return ReaderUI._koobone_original_showReader(self, file, ...)
                else
                    -- 无 MangaFit：Koobone 自己选官方 MuPDF provider（至少分页显示，无裁边）
                    local mupdf = comic_detect.find_mupdf_provider(file)
                    if mupdf then
                        return ReaderUI._koobone_original_showReader(self, file, mupdf, seamless, true, after_open_callback)
                    end
                end
            end

            -- 识别为文字或无法判定：透传 + 后处理 CSS 注入（仅 koobone 路径）
            local result = ReaderUI._koobone_original_showReader(self, file, ...)

            if is_koobone_path(file) then
                local UIManager = require("ui/uimanager")
                -- 等待 ReaderUI 和 styletweak 初始化完成
                UIManager:scheduleIn(2.0, function()
                    local ui = self
                    -- 校验当前文档仍是这次打开的那本（防止 2 秒内切到别的书）
                    local current = ui and ui.document
                    local current_path = current and (current.file or current.path)
                    if current_path ~= file then return end
                    -- MangaFit 已接管分页漫画时跳过 CSS 注入（MuPDF 模式下 styletweak 无效）
                    local fit = ui and ui.mangafit
                    if fit and fit.isPagedDocument and fit:isPagedDocument() then return end
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

    -- =========================================================================
    -- 补丁4：ReaderStyleTweak — 延迟的 updateCssText 在 ReaderUI 关闭后到达时跳过
    -- 场景：patchReaderUI 里 scheduleIn(2.0) 触发的 st:updateCssText(true) 可能在
    --       ReaderUI 已关闭、document 已 nil 后才执行，导致 stale 引用崩
    -- =========================================================================
    local ok_RST, ReaderStyleTweak = pcall(require, "apps/reader/modules/readerstyletweak")
    if ok_RST and ReaderStyleTweak and not ReaderStyleTweak._koobone_stale_stylesheet_guard_applied then
        local original_updateCssText = ReaderStyleTweak.updateCssText
        if type(original_updateCssText) == "function" then
            ReaderStyleTweak._koobone_stale_stylesheet_guard_applied = true
            ReaderStyleTweak.updateCssText = function(self, apply, ...)
                -- Koobone 延迟的样式更新可能在 ReaderUI 关闭后才到达，
                -- 此时 self.ui 或 self.ui.document 已 nil，应用会崩
                if apply and (not self.ui or not self.ui.document) then
                    return
                end
                return original_updateCssText(self, apply, ...)
            end
        end
    end

    -- =========================================================================
    -- 补丁5：Button — 异步书架重建后旧按钮 dimen 被清除，tap 队列仍触发时跳过 unsafe painting
    -- 场景：封面下载失败 → bookshelf 立即重建 UI → 旧按钮的 dimen 已 nil
    --       但 tap 队列里还有事件，触发 Button:onTapSelectButton 访问 frame.dimen 崩
    --       (button.lua:415 attempt to index field 'dimen' (a nil value))
    -- 修复：dimen 缺失时跳过 unsafe painting（高亮/invalidate），但 callback 仍执行
    -- =========================================================================
    local ok_Btn, Button = pcall(require, "ui/widget/button")
    if ok_Btn and Button and not Button._koobone_stale_tap_guard_applied then
        local original_onTapSelectButton = Button.onTapSelectButton
        if type(original_onTapSelectButton) == "function" then
            Button._koobone_stale_tap_guard_applied = true
            Button.onTapSelectButton = function(self, ...)
                local frame = self[1]
                if not frame or not frame.dimen then
                    -- 异步书架重建释放了按钮，但 tap 队列里仍有事件
                    -- 跳过 unsafe painting，但用户动作必须执行
                    if self.enabled or self.allow_tap_when_disabled then
                        if self.callback then
                            self.callback()
                        elseif self.tap_input then
                            self:onInput(self.tap_input)
                        elseif self.tap_input_func then
                            self:onInput(self.tap_input_func())
                        end
                    end
                    if self.readonly ~= true then
                        return true
                    end
                    return
                end
                return original_onTapSelectButton(self, ...)
            end
        end
    end
end

return M
