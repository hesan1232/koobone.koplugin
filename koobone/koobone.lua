local H = require("koobone.helper")

local Koobone = {}

-- 默认基础主机
Koobone.DEFAULT_HOST = "https://koobone.com"

-- 表单边界标记
Koobone.BOUNDARY = "----WebKitFormBoundaryForKoobone"

-- 规范化 base URL：补 https:// 前缀、去除末尾 /
function Koobone.normalize_base(base)
    local b = H.trim(base or "")
    if b == "" then
        b = Koobone.DEFAULT_HOST
    end
    if not b:match("^http") then
        b = "https://" .. b
    end
    if b:sub(-1) == "/" then
        b = b:sub(1, -2)
    end
    return b
end


-- 判断 base_host 是否指向本地
function Koobone.is_local_host(base_host)
    if not base_host then return false end
    local host = base_host:gsub("^https?://", ""):gsub(":%d+$", "")
    return host == "127.0.0.1" or host == "localhost"
end

-- 获取设备型号（KOReader Device.model），失败时返回 unknown
function Koobone.device_model()
    local ok_device, Device = pcall(require, "device")
    if ok_device and Device and Device.model then
        return tostring(Device.model)
    end
    return "unknown"
end

-- 构造鉴权头 X-KB-FROM：插件名/版本 + 设备型号
-- 与 test.py 对齐："koobone.koplugin/1.0.0 (Kindle; Oasis2)"
function Koobone.build_kb_from(version)
    version = version or "1.5.0"
    return "koobone.koplugin/" .. tostring(version) .. " (" .. Koobone.device_model() .. ")"
end

return Koobone
