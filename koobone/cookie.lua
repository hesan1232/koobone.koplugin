local Log = require("koobone.logger")
local H = require("koobone.helper")

local Cookie = {}
Cookie.__index = Cookie

local KEY_VLIBSID = "VLIBSID"
local KEY_KBSKEY = "KBSKEY"
local VALID_KEYS = { [KEY_VLIBSID] = true, [KEY_KBSKEY] = true }

local WEEKDAYS = {
    ["Mon"] = true, ["Tue"] = true, ["Wed"] = true, ["Thu"] = true,
    ["Fri"] = true, ["Sat"] = true, ["Sun"] = true,
}

function Cookie:new()
    local obj = setmetatable({
        _data = {},
    }, self)
    return obj
end

function Cookie.from_string(str)
    local cookie = Cookie:new()
    if not str or str == "" then
        return cookie
    end
    str = tostring(str)
    str = str:gsub("^%s*[Cc]ookie:%s*", "")
    for part in str:gmatch("([^;]+)") do
        local key, value = part:match("^%s*([^=]+)=(.-)%s*$")
        if key and value then
            key = H.trim(key)
            value = H.trim(value)
            if VALID_KEYS[key] then
                cookie._data[key] = value
            end
        end
    end
    return cookie
end

function Cookie:_split_set_cookie_segments(header_value)
    if not header_value or header_value == "" then
        return {}
    end
    header_value = tostring(header_value)
    local segments = {}
    local buf = ""
    local pos = 1
    local len = #header_value
    while pos <= len do
        local comma_pos = header_value:find(",", pos, true)
        if not comma_pos then
            buf = buf .. header_value:sub(pos)
            if H.trim(buf) ~= "" then
                table.insert(segments, H.trim(buf))
            end
            break
        end
        local before = header_value:sub(pos, comma_pos - 1)
        buf = buf .. before
        local after = header_value:sub(comma_pos + 1)
        local after_trimmed = H.trim(after)
        local is_weekday_continuation = false
        for wd, _ in pairs(WEEKDAYS) do
            if after_trimmed:sub(1, #wd) == wd then
                local next_char = after_trimmed:sub(#wd + 1, #wd + 1)
                if next_char == "," or next_char == " " or next_char == "\t" then
                    is_weekday_continuation = true
                    break
                end
            end
        end
        if is_weekday_continuation then
            buf = buf .. ","
            pos = comma_pos + 1
        else
            if H.trim(buf) ~= "" then
                table.insert(segments, H.trim(buf))
            end
            buf = ""
            pos = comma_pos + 1
        end
    end
    return segments
end

function Cookie:parse_set_cookie(header_value)
    if not header_value or header_value == "" then
        return
    end
    if type(header_value) == "table" then
        for _, v in pairs(header_value) do
            self:parse_set_cookie(v)
        end
        return
    end
    local segments = self:_split_set_cookie_segments(header_value)
    for _, seg in ipairs(segments) do
        local first_part = seg:match("^([^;]+)")
        if first_part then
            first_part = H.trim(first_part)
            local name, value = first_part:match("^([^=]+)=(.*)$")
            if name and value then
                name = H.trim(name)
                value = H.trim(value)
                if VALID_KEYS[name] then
                    self._data[name] = value
                    Log.debug("Cookie: 解析到 " .. name)
                end
            end
        end
    end
end

function Cookie:set(name, value)
    if not name then return end
    name = tostring(name)
    if not VALID_KEYS[name] then
        Log.warn("Cookie: 忽略非关键键名 " .. name)
        return
    end
    if value == nil then
        self._data[name] = nil
    else
        self._data[name] = tostring(value)
    end
end

function Cookie:get(name)
    if not name then return nil end
    return self._data[tostring(name)]
end

function Cookie:to_header_string()
    local parts = {}
    local vlibs = self._data[KEY_VLIBSID]
    local kbs = self._data[KEY_KBSKEY]
    if vlibs and vlibs ~= "" then
        table.insert(parts, KEY_VLIBSID .. "=" .. vlibs)
    end
    if kbs and kbs ~= "" then
        table.insert(parts, KEY_KBSKEY .. "=" .. kbs)
    end
    return table.concat(parts, "; ")
end

function Cookie:is_valid()
    local vlibs = self._data[KEY_VLIBSID]
    local kbs = self._data[KEY_KBSKEY]
    return vlibs ~= nil and vlibs ~= "" and kbs ~= nil and kbs ~= ""
end

function Cookie:clear()
    self._data = {}
end

function Cookie:save_to_settings(store, prefix)
    if not store then return false end
    prefix = prefix or "koobone_"
    local ok, err
    if store.set then
        ok, err = pcall(function()
            store:set(prefix .. "cookie_vlibsid", self._data[KEY_VLIBSID] or "")
            store:set(prefix .. "cookie_kbskey", self._data[KEY_KBSKEY] or "")
        end)
    elseif type(store) == "table" then
        store[prefix .. "cookie_vlibsid"] = self._data[KEY_VLIBSID] or ""
        store[prefix .. "cookie_kbskey"] = self._data[KEY_KBSKEY] or ""
        ok = true
    end
    if ok and store.flush then
        pcall(function() store:flush() end)
    end
    if not ok then
        Log.warn("Cookie: save_to_settings 失败: " .. tostring(err))
    end
    return ok == true
end

function Cookie:load_from_settings(store, prefix)
    if not store then return false end
    prefix = prefix or "koobone_"
    local vlibs, kbs
    local ok, err = pcall(function()
        if store.get then
            vlibs = store:get(prefix .. "cookie_vlibsid", "")
            kbs = store:get(prefix .. "cookie_kbskey", "")
        elseif type(store) == "table" then
            vlibs = store[prefix .. "cookie_vlibsid"]
            kbs = store[prefix .. "cookie_kbskey"]
        end
    end)
    if not ok then
        Log.warn("Cookie: load_from_settings 失败: " .. tostring(err))
        return false
    end
    if vlibs and vlibs ~= "" then
        self._data[KEY_VLIBSID] = tostring(vlibs)
    end
    if kbs and kbs ~= "" then
        self._data[KEY_KBSKEY] = tostring(kbs)
    end
    return true
end

function Cookie:save_to_file(path)
    if not path then return false end
    local str = self:to_header_string()
    local ok, err = pcall(function()
        H.make_dir(path:match("^(.*)[/\\]"))
        local f = io.open(path, "wb")
        if not f then error("无法打开文件") end
        f:write(str)
        f:close()
    end)
    if not ok then
        Log.warn("Cookie: save_to_file 失败: " .. tostring(err))
        return false
    end
    return true
end

function Cookie:load_from_file(path)
    if not path or not H.file_exists(path) then
        return false
    end
    local ok, err = pcall(function()
        local f = io.open(path, "rb")
        if not f then error("无法打开文件") end
        local str = f:read("*a") or ""
        f:close()
        if str ~= "" then
            local temp = Cookie.from_string(str)
            self._data = temp._data
        end
    end)
    if not ok then
        Log.warn("Cookie: load_from_file 失败: " .. tostring(err))
        return false
    end
    return true
end

return Cookie
