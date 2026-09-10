local Log = require("koobone.logger")
local H = require("koobone.helper")
local Koobone = require("koobone.koobone")

local ok_info, Info = pcall(require, "koobone.info")
local AUTH_VERSION = ok_info and Info and Info.version or "0.2.0"

local Auth = {}
Auth.__index = Auth

local DEFAULT_HOST = Koobone.DEFAULT_HOST

function Auth:new(settings)
    local obj = setmetatable({
        settings = settings,
    }, self)
    obj:load_from_settings()
    return obj
end

function Auth:load_from_settings()
    if not self.settings then return end
    local store = self.settings
    -- 统一使用 Settings 的标准 getter（读取 auth 嵌套表）
    if store.get_api_key then
        self.api_key = store:get_api_key() or ""
        self.uin = store:get_uin() or ""
        self.base_host = store:get_base_host() or DEFAULT_HOST
    elseif store.get then
        -- 兼容: 直接从 auth 表读取
        local auth_tbl = store:get("auth") or {}
        self.api_key = auth_tbl.api_key or ""
        self.uin = tostring(auth_tbl.uin or "")
        self.base_host = auth_tbl.base_host or DEFAULT_HOST
    end
end

function Auth:save_to_settings()
    if not self.settings then return false end
    local store = self.settings
    local ok, err = pcall(function()
        if store.set_api_key then
            store:set_api_key(self.api_key or "")
            store:set_uin(self.uin or "")
            if self.base_host and self.base_host ~= "" then
                store:set_base_host(self.base_host)
            end
        elseif store.set then
            -- 兼容: 直接写 auth 表
            local auth_tbl = store:get("auth") or {}
            auth_tbl.api_key = self.api_key or ""
            auth_tbl.uin = tostring(self.uin or "")
            if self.base_host and self.base_host ~= "" then
                auth_tbl.base_host = self.base_host
            end
            store:set("auth", auth_tbl)
        end
    end)
    if not ok then
        Log.warn("Auth: save_to_settings 失败: " .. tostring(err))
        return false
    end
    if store.flush then
        pcall(function() store:flush() end)
    end
    return true
end

function Auth:get_api_key()
    if self.settings and self.settings.get_api_key then
        return self.settings:get_api_key() or ""
    end
    return self.api_key or ""
end

function Auth:set_api_key(v)
    self.api_key = H.trim(v or "")
    if self.settings and self.settings.set_api_key then
        self.settings:set_api_key(self.api_key)
        pcall(function() self.settings:flush() end)
    end
end

function Auth:is_logged_in()
    return self:get_api_key() ~= ""
end

function Auth:clear()
    self.api_key = ""
    self.uin = ""
    self:save_to_settings()
end

return Auth
