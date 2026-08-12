local _ = require("gettext")
local ok_info, Info = pcall(require, "koobone.info")
return {
    name = "koobone",
    fullname = ok_info and Info and Info.fullname or _("Koobone 漫画"),
    description = ok_info and Info and Info.description
        or _("在 KOReader 中阅读 Koobone 漫画库，支持下载、进度同步、排序和预下载。"),
    version = ok_info and Info and Info.version or "0.2.0",
}
