-- 插件元信息集中管理：版本号、描述、关于文案
-- 所有需要展示版本/关于的地方统一从这里读取，避免多处维护不同步。
--   - main.lua: require("koobone.info") 读取 version 和 about_template
--   - _meta.lua: pcall(require, "koobone.info") 读取 version 和 description
--
-- about_template 用 T() 格式化，占位符：
--   %1 = 版本号（version）

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

return {
    -- 版本号（唯一来源，main.lua 和 _meta.lua 都读这里）
    version = "0.2.0",

    -- 插件描述（_meta.lua 的 description 字段使用）
    description = _("Koobone 漫画资源库插件，支持书架浏览、批量下载、EPUB 缓存、进度云端同步，适配墨水屏黑白显示。"),

    -- 插件全名（main.lua 的 fullname 使用）
    fullname = _("Koobone 漫画"),

    -- 关于文案模板：main.lua 「关于插件」对话框使用
    -- 修改文案只需改这一处
    about_template = _("Koobone 漫画插件 v%1\n\n核心特性:\n• 书架浏览（按更新/名称/最后阅读）\n• 漫画下载与断点续传（带进度条）\n• EPUB 缓存与 LRU 自动清理\n• 阅读进度云端同步\n• 智能预下载下 N 卷\n• 后台静默刷新不打断阅读"),
}
