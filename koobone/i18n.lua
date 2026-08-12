-- Koobone 多语言模块
-- 用法：
--   local I18n = require("koobone.i18n")
--   local txt = I18n.tr("Downloading: %1")
--   print(I18n.is_zh()) -- true 时使用中文翻译
--
-- 设计：
--   - 键为英文（即 KOReader 默认英文界面时原样显示）
--   - zh 表中映射为中文翻译
--   - 新增字符串只需在下方 zh 字典中加一行即可
--   - 若某条没有翻译，tr() 返回原英文键（英文界面下也能正常显示）

local I18n = {}

-- 中文翻译表（键 = 英文字符串，值 = 中文翻译）
-- 新增文案时，在 _() 中写英文键，然后在此表中补中文
local zh = {
    -- ===== 基础 UI 文本 =====
    ["Koobone Comics"] = "Koobone 漫画",
    ["Koobone"] = "Koobone 漫画",
    ["Koobone Bookshelf"] = "Koobone 书架",
    ["Bookshelf"] = "书架",
    ["Settings"] = "设置",
    ["Settings module not loaded"] = "设置模块未加载",
    ["Settings build failed, see logs"] = "设置构建失败，请查看日志",
    ["No settings available"] = "暂无设置项",
    ["About Plugin"] = "关于插件",
    ["Back to Koobone Bookshelf"] = "返回 Koobone 书架",
    ["Back to Bookshelf"] = "返回书架",
    ["Open Bookshelf"] = "打开书架",
    ["Please wait..."] = "请稍候...",
    ["Cancel"] = "取消",
    ["Confirm"] = "确定",
    ["OK"] = "确定",
    ["Save"] = "保存",
    ["Close"] = "关闭",
    ["Download"] = "下载",
    ["Clear"] = "清除",
    ["Keep"] = "保留",
    ["Move"] = "移动",
    ["Done"] = "已完成",
    ["Ready"] = "就绪",
    ["Error"] = "错误",
    ["Warning"] = "警告",
    ["Untitled"] = "未命名",
    ["Untitled series"] = "未命名系列",
    ["Just now"] = "刚刚",
    ["%d minutes ago"] = "%d 分钟前",
    ["%d hours ago"] = "%d 小时前",
    ["%d days ago"] = "%d 天前",

    -- ===== 认证 / 登录 =====
    ["Account (email)"] = "账号 (邮箱)",
    ["Account Settings"] = "账号设置",
    ["Account saved"] = "账号已保存",
    ["Password"] = "密码",
    ["Please enter email"] = "请输入邮箱账号",
    ["Please enter password"] = "请输入密码",
    ["Please enter account and password"] = "请先填写账号和密码",
    ["Save and Login"] = "保存并登录",
    ["Logging in..."] = "正在登录...",
    ["Login successful"] = "登录成功",
    ["Login failed"] = "登录失败",
    ["Login error: "] = "登录异常: ",
    ["Login expired, please re-login in Koobone settings."] = "登录已过期，请在 Koobone 设置中重新登录。",
    ["Not logged in, please login in Koobone settings"] = "未登录，请先在 Koobone 设置中登录",
    ["Testing Cookie..."] = "正在测试 Cookie...",
    ["Cookie valid"] = "Cookie 有效",
    ["Cookie expired"] = "Cookie 失效",
    ["Cookie empty, please login or fill Cookie first"] = "Cookie 为空，请先登录或填写 Cookie",
    ["Auth module not initialized"] = "认证模块未初始化",

    -- ===== 书架 / 浏览 =====
    ["Fetching bookshelf..."] = "正在获取书架...",
    ["Loading bookshelf..."] = "正在加载书架...",
    ["Loading bookshelf failed:\n%1"] = "获取书架失败:\n%1",
    ["Bookshelf empty\nPlease check network or login status"] = "书架为空\n请检查网络或登录状态",
    ["Bookshelf module not loaded"] = "书架模块未加载",
    ["Refreshing bookshelf..."] = "正在刷新书架...",
    ["Refresh failed:\n%1"] = "刷新失败:\n%1",
    ["Refresh Bookshelf"] = "刷新书架",
    ["%1, showing stale cache"] = "%1，已显示旧缓存",
    ["Sort by"] = "排序方式",
    ["By updated time"] = "按更新时间",
    ["By title"] = "按漫画名称",
    ["By name"] = "按名称",
    ["By last read"] = "按最后阅读",
    ["Open series"] = "打开系列",
    ["Series details"] = "系列详情",
    ["Back to series list"] = "返回系列列表",
    ["No volumes in this series\nPlease check network or return to bookshelf"] = "该系列无卷\n请检查网络或返回书架",

    -- ===== 下载 =====
    ["Downloading"] = "下载中",
    ["Preparing download"] = "准备下载",
    ["Preparing..."] = "准备下载……",
    ["Extracting"] = "解压中",
    ["Parsing"] = "解析中",
    ["Not started"] = "未开始",
    ["Processing"] = "处理中",
    ["Cancelling..."] = "正在取消……",
    ["Download cancelled"] = "下载已取消",
    ["Cancelled"] = "已取消",
    ["Interrupted, incomplete"] = "中断，未完成",
    ["Incomplete"] = "未完成",
    ["Download complete"] = "下载完成",
    ["Cached"] = "已缓存",
    ["Downloading: %s\n%s/%s  (%d%%)\n%s"] = "下载中：%s\n%s/%s  (%d%%)\n%s",
    ["Cancel Download"] = "取消下载",
    ["Bookshelf actions"] = "书架操作",
    ["Series actions"] = "系列操作",
    ["Volume actions"] = "卷操作",
    ["Download this volume"] = "下载本卷",
    ["Download all uncached"] = "下载全部未缓存",
    ["Pre-download: this volume + next uncached"] = "预下载：本卷+后续未缓存",
    ["All subsequent volumes already downloaded"] = "后续卷都已下载完成",
    ["All volumes in this series already downloaded"] = "该系列已全部下载完成",
    ["No downloadable volumes in this series"] = "该系列无卷可下载",
    ["Queued for download: %d volumes"] = "已加入下载队列：%d 卷",
    ["Run in background"] = "后台运行",
    ["Download moved to background"] = "下载已转入后台",
    ["Download failed"] = "下载失败",
    ["Download failed: "] = "下载失败: ",
    ["This volume already downloaded, re-download?"] = "该卷已下载，是否重新下载？",
    ["Re-download"] = "重新下载",
    ["Download module not loaded"] = "下载模块未加载",
    ["Download module not ready"] = "下载模块未就绪",
    ["Download Settings"] = "下载设置",
    ["Invalid volume id"] = "无效的卷标识",
    ["No series info for this volume"] = "该卷无系列信息",
    ["\"%1\" download complete!"] = "《%1》下载完成！",
    ["%d volumes"] = "%d 卷",
    ["%s / %s"] = "%s / %s",

    -- ===== 阅读器 =====
    ["Open for reading"] = "打开阅读",
    ["Comic id invalid"] = "漫画标识无效",
    ["Comic not found"] = "未找到该漫画",
    ["EPUB not downloaded"] = "EPUB 文件未下载",
    ["Cannot load reader"] = "无法加载阅读器",
    ["Reader module not ready"] = "阅读模块未就绪",
    ["Open failed:\n%1"] = "打开失败:\n%1",

    -- ===== 进度同步 =====
    ["Sync Settings"] = "同步设置",
    ["Auto-pull progress on open"] = "进入时自动拉取进度",
    ["Manually upload progress to cloud"] = "手动上传云端进度",
    ["Progress upload interval (seconds)"] = "进度上传间隔(秒)",
    ["Upload interval saved"] = "上传间隔已保存",
    ["Please enter seconds (0 = disabled)"] = "请输入秒数 (0 表示关闭)",
    ["Please enter a valid number"] = "请输入有效数字",
    ["Uploading progress..."] = "正在上传云端进度...",
    ["Cloud progress updated"] = "云端进度已更新",
    ["Upload failed:\n%1"] = "上传失败:\n%1",
    ["Upload failed: missing volume info"] = "上传失败：卷信息缺失",
    ["Upload failed: network module not ready"] = "上传失败：网络模块未就绪",
    ["Pre-download chapters count"] = "预下载章节数",
    ["Pre-download N chapters while reading (0 = off)"] = "阅读时提前下载后 N 章 (0 表示不预下载)",
    ["Pre-download settings saved"] = "预下载设置已保存",

    -- ===== 缓存管理 =====
    ["Cache Management"] = "缓存管理",
    ["Delete local cache"] = "删除本地缓存",
    ["Local cache deleted"] = "已删除本地缓存",
    ["Confirm delete local cache?\n%1\n(Cloud library content will NOT be deleted)"] = "确认删除本地缓存？\n%1\n（云端书库中内容不会被删除）",
    ["Delete failed:\n%1"] = "删除失败:\n%1",
    ["Clear all cache"] = "清除所有缓存",
    ["Confirm clear all covers and EPUB cache?"] = "确定要清除封面和 EPUB 缓存吗？",
    ["Cleared %d covers, %d EPUBs"] = "已清除封面 %d 个, EPUB %d 个",

    -- ===== 设置 / 日志 =====
    ["Settings saved"] = "设置已保存",
    ["Site URL"] = "网站地址",
    ["Debug Logs"] = "调试日志",
    ["View Logs"] = "查看日志",
    ["Logger module not loaded"] = "日志模块未加载",
    ["(Log file empty or does not exist)"] = "(日志文件为空或不存在)",
    ["Log path: %1"] = "日志路径: %1",
    ["Log file path:\n%s"] = "日志文件路径:\n%s",
    ["Koobone Logs"] = "Koobone 日志",

    -- ===== 通用错误 / 状态 =====
    ["%1 failed:\n%2"] = "%1 failed:\n%2",
    ["About"] = "关于",
    ["Save only"] = "仅保存",
    ["Test error: "] = "测试异常: ",
    ["Pre-download chapters"] = "预下载章节数",
}

-- 检测当前 KOReader 语言设置
function I18n.language()
    local lang
    -- Use pcall to safely access G_reader_settings (may not exist in all KOReader versions)
    local ok, result = pcall(function()
        if G_reader_settings and G_reader_settings.readSetting then
            return G_reader_settings:readSetting("language")
        end
        return nil
    end)
    if ok and result then
        lang = result
    end
    -- Also try reading from KOReader module
    if not lang then
        ok, result = pcall(function()
            local KOReader = require("koreader")
            return KOReader.readSetting and KOReader:readSetting("language")
        end)
        if ok and result then
            lang = result
        end
    end
    return lang or "en"
end

function I18n.is_zh()
    return tostring(I18n.language()):lower():match("^zh") ~= nil
end

-- 翻译函数：中文环境返回 zh 表中的翻译，否则返回原文（英文）
function I18n.tr(text)
    if I18n.is_zh() then
        return zh[text] or text
    end
    return text
end

return I18n
