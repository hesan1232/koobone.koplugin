-- Koobone 漫画插件配置示例（复制为 config.lua 后生效，config.lua 已在 .gitignore 中）
-- 【推荐】优先在 KOReader 界面的「Koobone 设置」中填写，配置会持久化到 KOReader settings/koobone.lua
-- 只有需要自动化部署时才编辑本文件；界面填写值优先级高于本文件

return {
    -- API Key（从 koobone.com 个人页面获取，插件直接放到 X-KB-INFO 请求头进行鉴权）
    -- 格式示例："kbs-xxxxxxxxxxx（空格会被自动忽略）
    api_key = "",

    -- 网站地址（可选，默认 https://koobone.com）
    base_host = "https://koobone.com",

    -- 登录后自动获取的用户 uin（可选，留空会自动从 API 获取）
    uin = "",

    -- 书架默认排序："uptime" = 按更新时间，"vol_name" = 按名字
    shelf_sort = "uptime",

    -- 是否下载封面图片（墨水屏可关闭以节省空间和流量，默认开启）
    download_covers = true,

    -- 缓存 EPUB 的最大体积（MB），超过会自动清理最久未访问的
    cache_max_size_mb = 1024,

    -- 预下载：阅读时提前下载后 N 页（0 表示不预下载）
    pre_download_pages = 3,

    -- 进度自动上传间隔（秒），0 表示仅离开阅读器时上传
    progress_upload_interval = 60,
}
