-- 插件自更新器（参考觅阅 miuread 的 updater 设计，并按本插件的实际情况做了三处改动）。
--
-- 【整体流程】
--   check()     拉 update.json 清单（含镜像回退）→ 校验字段 → 语义化版本比对
--   download()  按 package_url / package_urls / mirrors 逐个试 → 校验 size + SHA-256
--   install()   解压到 stage → 校验包结构 + 包内版本号 → 备份 → 替换 → 保留用户配置
--   startup()   KOReader 启动时调用：比对「记录的期望版本」与「当前运行版本」
--               一致 = 上一步的替换真的生效了 → 删掉备份，更新完成
--               不一致 = 替换没生效 → **保留备份**，UI 可据此提示/回滚
--
-- 【相对觅阅的三处必要改动】
--   1. 必须保留用户的 `config.lua`。本插件的 config.lua 存着 API Key，而它在
--      `.gitignore` 里（不会进包），全量替换会把它删掉 —— 用户更新一次就得重新填 Key。
--      觅阅的配置存在 LuaSettings 里、不在包内，所以它没有这个问题。
--   2. 解压用 KOReader 自带的 `ffi/archiver`（纯 Lua），不调系统 `unzip` 命令 ——
--      觅阅依赖 `unzip -q`，而设备上不保证有它（Kindle 的 busybox 就没有）。
--   3. 包内版本号从 `koobone/info.lua` 读（本插件版本的唯一来源），不是 config.lua。
--
-- 【本模块是同步的】所有网络请求与文件操作都在当前线程完成 —— 调用方必须用
-- `Async.run` 把它丢进子进程，否则会阻塞 UI（KOReader 主线程卡死表现为整机无响应）。

local lfs = require("libs/libkoreader-lfs")

local H = require("koobone.helper")
local Log = require("koobone.logger")
local Digests = require("koobone.digests")
local Http = require("koobone.updater_http")
local Info = require("koobone.info")

local Updater = {}
Updater.__index = Updater

-- ============================================================
-- 发布配置
-- ============================================================

--- 更新清单地址。仓库是 public，走 raw.githubusercontent（国内直连基本不通，
--- 下面 GITHUB_MIRRORS 会自动为它生成镜像地址）。
local MANIFEST_URLS = {
    "https://raw.githubusercontent.com/hesan1232/koobone.koplugin/main/update.json",
}

--- GitHub 加速镜像。用法是「前缀 + 原始完整 URL」。
--- 镜像只影响**下载速度**，不影响安装内容 —— 下载后仍强制校验 SHA-256。
local GITHUB_MIRRORS = {
    "https://ghfast.top/",
    "https://gh-proxy.com/",
    "https://ghproxy.net/",
}

local UPDATE_CHANNEL = "stable"
local PACKAGE_ROOT = "koobone.koplugin"  -- zip 包内唯一根目录名
local NOTES_MAX_LINES = 12

-- ============================================================
-- 小工具
-- ============================================================

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

--- 写文件；write 与 close 的返回值都要查（磁盘满时错误常常只在 close 暴露）。
local function write_file(path, data)
    local f, err = io.open(path, "wb")
    if not f then return nil, tostring(err) end
    local ok_write, werr = f:write(data)
    local ok_close, cerr = f:close()
    if not ok_write then return nil, tostring(werr) end
    if ok_close == nil then return nil, tostring(cerr) end
    return true
end

--- 递归复制文件树。用于「备份插件目录」与「从备份回滚」。
local function copy_tree(src, dst)
    local mode = lfs.attributes(src, "mode")
    if mode == "directory" then
        H.make_dir(dst)
        for entry in lfs.dir(src) do
            if entry ~= "." and entry ~= ".." then
                local ok, err = copy_tree(src .. "/" .. entry, dst .. "/" .. entry)
                if not ok then return nil, err end
            end
        end
        return true
    elseif mode == "file" then
        local data = read_file(src)
        if not data then return nil, "读取失败 " .. src end
        return write_file(dst, data)
    end
    return true  -- 其它类型（符号链接等）跳过
end

local function list_dir(path)
    local out = {}
    if not H.dir_exists(path) then return out end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then out[#out + 1] = entry end
    end
    return out
end

--- 把版本号解析成 数字三元组（只认 x.y.z，忽略 v 前缀与预发布后缀）。
local function parse_version(value)
    local major, minor, patch = tostring(value or ""):match("^v?(%d+)%.(%d+)%.(%d+)")
    if not major then return nil end
    return tonumber(major), tonumber(minor), tonumber(patch)
end

local function version_newer(a, b)
    local a1, a2, a3 = parse_version(a)
    local b1, b2, b3 = parse_version(b)
    if not a1 or not b1 then
        -- 解析不了就退化成字符串比较，至少不会永远判「有新版本」
        return tostring(a) ~= tostring(b) and tostring(a) > tostring(b)
    end
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    return a3 > b3
end

--- 清洗更新说明：去掉控制字符、压缩空行、限行数。
--- 清单内容要直接进 InfoMessage，控制字符会让 KOReader 的排版崩掉。
local function clean_notes(value)
    local text = tostring(value or "")
    if text == "" then return "" end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[%z\1-\8\11\12\14-\31]", "")
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            lines[#lines + 1] = line
            if #lines >= NOTES_MAX_LINES then break end
        end
    end
    return table.concat(lines, "\n")
end

local function is_github_url(url)
    return url:match("^https://github%.com/") ~= nil
        or url:match("^https://raw%.githubusercontent%.com/") ~= nil
end

--- 把 url 追加进 out，GitHub 资源再额外追加各镜像版本。
local function expand_url(url, out, seen)
    if type(url) ~= "string" or not url:match("^https://") then return end
    if seen[url] then return end
    seen[url] = true
    out[#out + 1] = url

    if not is_github_url(url) then return end
    for _, prefix in ipairs(GITHUB_MIRRORS) do
        if type(prefix) == "string" and prefix:match("^https://") then
            local normalized = prefix:sub(-1) == "/" and prefix or (prefix .. "/")
            local mirrored = normalized .. url
            if not seen[mirrored] then
                seen[mirrored] = true
                out[#out + 1] = mirrored
            end
        end
    end
end

local function collect_urls(values, out, seen)
    if type(values) == "table" then
        for _, url in ipairs(values) do expand_url(url, out, seen) end
    end
end

--- 从清单里汇总所有安装包地址（package_url 单值 + 各兼容字段的数组）。
local function package_urls(manifest)
    local out, seen = {}, {}
    if type(manifest) ~= "table" then return out end
    expand_url(manifest.package_url or manifest.url, out, seen)
    collect_urls(manifest.package_urls, out, seen)
    collect_urls(manifest.mirror_urls, out, seen)
    collect_urls(manifest.mirrors, out, seen)
    return out
end

--- @return true | nil, string 原因
local function validate_manifest(m)
    if type(m) ~= "table" then return nil, "清单格式错误" end
    if type(m.version) ~= "string" or m.version == "" then
        return nil, "清单缺少版本号"
    end

    local channel = tostring(m.channel or "")
    if channel == "" then channel = "stable" end
    if channel ~= UPDATE_CHANNEL then
        return nil, "清单通道不匹配（当前 " .. UPDATE_CHANNEL .. "，清单 " .. channel .. "）"
    end

    if m.package_type ~= nil and tostring(m.package_type) ~= "full" then
        return nil, "清单不是全量包"
    end
    if #package_urls(m) == 0 then
        return nil, "清单缺少安装包地址"
    end

    local sha = tostring(m.sha256 or ""):lower():gsub("%s+", "")
    if not sha:match("^%x{64}$") then
        return nil, "清单缺少合法的 SHA-256"
    end
    return true
end

-- ============================================================
-- 构造
-- ============================================================

--- 模块加载时反推插件根目录（<...>/koobone.koplugin）。
-- 正常 KOReader 用 loadfile 加载（source 带 @ 前缀）；取不到时由调用方传 plugin_root。
local function detect_plugin_root()
    local source = debug.getinfo(1, "S").source or ""
    return source:match("^@(.*)/koobone/updater%.lua$")
end

function Updater:new(opts)
    opts = opts or {}
    local updates_dir = H.get_data_dir() .. "/updates"
    H.make_dir(updates_dir)

    return setmetatable({
        version = opts.version or (Info and Info.version) or "0.0.0",
        plugin_root = opts.plugin_root or detect_plugin_root(),
        updates_dir = updates_dir,
        state_file = updates_dir .. "/state.json",
    }, self)
end

-- ============================================================
-- 状态持久化（updates/state.json）
-- ============================================================

function Updater:_load_state()
    local data = read_file(self.state_file)
    if not data then return {} end
    local decoded = H.json_decode(data)
    return type(decoded) == "table" and decoded or {}
end

function Updater:_save_state(value)
    local ok, encoded = pcall(H.json_encode, value or {})
    if not ok or type(encoded) ~= "string" then
        Log.warn("[Updater] 状态序列化失败")
        return false
    end
    local wrote, err = write_file(self.state_file, encoded)
    if not wrote then
        -- 状态写不出去必须报出来：install 后靠它判断「更新是否生效」，
        -- 静默失败会让 startup() 永远认为没有待确认的更新。
        Log.error("[Updater] 状态写入失败：" .. tostring(err))
        return false
    end
    return true
end

function Updater:is_pending()
    return self:_load_state().pending == true
end

-- ============================================================
-- 清理
-- ============================================================

local function artifact_kind(name)
    if name:match("^stage%-") then return "stage" end
    if name:match("^backup%-") then return "backup" end
    if name:match("%.zip$") then return "package" end
    return nil
end

--- 删除 updates/ 下遗留的 stage / backup / zip。
-- @param protected table|nil  以**完整路径或文件名**为键的豁免表（正在使用的不删）
function Updater:cleanup_artifacts(protected)
    protected = protected or {}
    local removed = { stage = 0, backup = 0, package = 0 }
    for _, name in ipairs(list_dir(self.updates_dir)) do
        local kind = artifact_kind(name)
        local full = self.updates_dir .. "/" .. name
        if kind and not protected[name] and not protected[full] then
            H.delete_dir(full)
            removed[kind] = removed[kind] + 1
        end
    end
    local total = removed.stage + removed.backup + removed.package
    if total > 0 then
        Log.info(string.format("[Updater] 清理更新残留 stage=%d backup=%d package=%d",
            removed.stage, removed.backup, removed.package))
    end
    return removed
end

--- 删除已下载的安装包（成功或失败后都该删，几百 KB 不必留着）
function Updater:_remove_package(path)
    if type(path) ~= "string" or path == "" then return false end
    -- 只删本插件 updates 目录内的 .zip，避免误删用户文件
    if path:sub(1, #self.updates_dir + 1) ~= (self.updates_dir .. "/") then return false end
    if not path:match("%.zip$") then return false end
    H.delete_file(path)
    return true
end

-- ============================================================
-- 检查更新
-- ============================================================

function Updater:manifest_urls()
    local out, seen = {}, {}
    for _, url in ipairs(MANIFEST_URLS) do expand_url(url, out, seen) end
    return out
end

--- 拉取并校验清单。
-- @return table 结果 | nil, string 原因
--         结果里带 `current = true` 表示「不落后于清单版本」，否则为可安装的清单。
function Updater:check()
    local urls = self:manifest_urls()
    if #urls == 0 then return nil, "更新地址未配置" end

    local errors = {}
    for _, url in ipairs(urls) do
        local manifest, err = Http.get_json(url, { timeout = 30 })
        if type(manifest) == "table" then
            local valid, reason = validate_manifest(manifest)
            if valid then
                local notes = clean_notes(manifest.notes or manifest.summary)
                Log.info("[Updater] 清单已读取 " .. url .. " version=" .. tostring(manifest.version))
                if not version_newer(manifest.version, self.version) then
                    return { current = true, version = manifest.version, notes = notes }
                end
                manifest.notes = notes
                manifest.summary = clean_notes(manifest.summary) or manifest.notes
                return manifest
            end
            errors[#errors + 1] = tostring(reason)
            Log.warn("[Updater] 清单校验失败 " .. url .. "：" .. tostring(reason))
        else
            errors[#errors + 1] = tostring(err)
            Log.warn("[Updater] 清单请求失败 " .. url .. "：" .. tostring(err))
        end
    end
    return nil, errors[#errors] or "无法读取更新清单"
end

-- ============================================================
-- 下载
-- ============================================================

--- 下载安装包并校验完整性。
-- @return string 本地路径 | error(string)  —— 故意 error 而非返回 nil，
--         这样调用方 pcall 与直接调用的写法都不会把「失败」误当成功。
function Updater:download(manifest)
    if self:is_pending() then
        error("上次更新尚未确认，请完整重启 KOReader 后再更新")
    end
    if not Digests.available() then
        error("本设备缺少 bit 库，无法校验更新包，已中止")
    end

    self:cleanup_artifacts()

    local urls = package_urls(manifest)
    if #urls == 0 then error("更新包地址无效") end

    local expected_sha = tostring(manifest.sha256 or ""):lower():gsub("%s+", "")
    if expected_sha == "" then error("清单缺少 SHA-256") end
    local expected_size = tonumber(manifest.size or manifest.bytes or manifest.package_size)

    local target = self.updates_dir .. "/koobone-" .. tostring(manifest.version) .. ".zip"
    local last_error = "下载失败"

    for index, url in ipairs(urls) do
        local ok, size_or_err = Http.download(url, target, { timeout = 120 })
        if ok then
            local raw = read_file(target)
            if type(raw) == "string" and #raw > 0 then
                if expected_size and expected_size > 0 and #raw ~= expected_size then
                    last_error = string.format("更新包大小不符（期望 %d，实际 %d）", expected_size, #raw)
                    Log.warn("[Updater] 大小不符 " .. url)
                else
                    local actual = Digests.sha256(raw)
                    if actual and actual:lower() == expected_sha then
                        Log.info(string.format("[Updater] 更新包下载完成 source=%d bytes=%d", index, #raw))
                        return target
                    end
                    last_error = "更新包 SHA-256 校验失败"
                    Log.warn("[Updater] SHA-256 不符 " .. url)
                end
            else
                last_error = "下载内容为空"
            end
        else
            last_error = tostring(size_or_err or "下载失败")
        end
        H.delete_file(target)
    end

    error(last_error)
end

-- ============================================================
-- 安装
-- ============================================================

--- 解压后单文件/单目录的安装形态校验：只能有一个 PACKAGE_ROOT 根目录。
local function validate_unpacked(unpacked)
    local roots = list_dir(unpacked)
    if #roots ~= 1 or roots[1] ~= PACKAGE_ROOT then
        return nil, "更新包根目录必须只包含 " .. PACKAGE_ROOT
    end
    local incoming = unpacked .. "/" .. PACKAGE_ROOT
    if not H.file_exists(incoming .. "/main.lua") or not H.file_exists(incoming .. "/_meta.lua") then
        return nil, "更新包缺少 main.lua / _meta.lua"
    end
    -- 凭证文件绝不该出现在发布包里：真出现说明发布流程出错（把本地 config 打进去了），
    -- 装上会把用户原有的凭证覆盖成别人的。直接拒绝。
    if H.file_exists(incoming .. "/config.lua") then
        return nil, "更新包包含 config.lua，已拒绝安装（发布包不应含用户凭证）"
    end
    return incoming
end

--- 读包内声明的版本号（本插件版本的唯一来源是 koobone/info.lua）。
function Updater:_read_package_version(plugin_dir)
    local data = read_file(plugin_dir .. "/koobone/info.lua")
    if not data then return nil end
    return data:match('version%s*=%s*"([^"]+)"')
end

--- 安装已下载的包。成功返回 true；失败返回 nil + 原因（并已尽量回滚）。
function Updater:install(path, manifest)
    if self:is_pending() then
        self:_remove_package(path)
        return nil, "上次更新尚未确认，请完整重启 KOReader 后再更新"
    end
    if not Digests.available() then
        return nil, "本设备缺少 bit 库，无法校验更新包"
    end
    if not self.plugin_root or self.plugin_root == "" then
        return nil, "无法定位插件目录，已中止"
    end

    local stamp = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
    local stage = self.updates_dir .. "/stage-" .. stamp
    local unpacked = stage .. "/unpacked"
    local backup = self.updates_dir .. "/backup-" .. stamp

    self:cleanup_artifacts()
    H.delete_dir(stage)
    H.delete_dir(backup)
    H.make_dir(unpacked)

    local function fail(message)
        H.delete_dir(stage)
        H.delete_dir(backup)
        self:_remove_package(path)
        return nil, message
    end

    -- 1) 解压（ffi/archiver，纯 Lua，不依赖系统 unzip）
    local unzipped, unzip_err = H.unzip_file(path, unpacked)
    if not unzipped then
        return fail("解压更新包失败：" .. tostring(unzip_err))
    end

    -- 2) 包结构校验
    local incoming, structure_err = validate_unpacked(unpacked)
    if not incoming then
        return fail(structure_err)
    end

    -- 3) 包内版本号必须与清单一致（防止清单与包错配 —— 那会导致
    --    startup() 的「重启后确认」永远对不上，用户卡在 pending 状态）
    local incoming_version = self:_read_package_version(incoming)
    if tostring(incoming_version or "") ~= tostring(manifest.version or "") then
        return fail(string.format("更新包版本（%s）与清单（%s）不一致",
            tostring(incoming_version or "未知"), tostring(manifest.version or "未知")))
    end

    -- 4) 备份当前插件
    local backed_up, backup_err = copy_tree(self.plugin_root, backup)
    if not backed_up then
        return fail("备份当前插件失败：" .. tostring(backup_err))
    end

    -- 5) 记住用户的配置（备份里有，替换后写回）
    local saved_config = read_file(backup .. "/config.lua")

    local function rollback(message)
        H.delete_dir(self.plugin_root)
        local restored, restore_err = copy_tree(backup, self.plugin_root)
        H.delete_dir(stage)
        self:_remove_package(path)
        if not restored then
            return nil, string.format("%s；回滚也失败：%s；备份保留在 %s",
                tostring(message), tostring(restore_err), backup)
        end
        H.delete_dir(backup)
        return nil, tostring(message) .. "；已恢复旧版本"
    end

    -- 6) 替换：优先 rename（快），失败退回递归复制
    H.delete_dir(self.plugin_root)
    H.make_dir(self.plugin_root)
    local renamed = os.rename(incoming, self.plugin_root)
    if not renamed then
        local copied, copy_err = copy_tree(incoming, self.plugin_root)
        if not copied then
            return rollback("安装新文件失败：" .. tostring(copy_err))
        end
    end

    -- 7) 写回用户配置
    if saved_config then
        local wrote, write_err = write_file(self.plugin_root .. "/config.lua", saved_config)
        if not wrote then
            return rollback("恢复 config.lua 失败：" .. tostring(write_err))
        end
        Log.info("[Updater] 已保留用户 config.lua")
    end

    -- 8) 替换后完整性校验
    if not H.file_exists(self.plugin_root .. "/main.lua")
        or not H.file_exists(self.plugin_root .. "/_meta.lua") then
        return rollback("安装后的插件文件不完整")
    end

    H.delete_dir(stage)

    -- 9) 记录待确认状态。startup() 靠它判断这次替换是否真的生效。
    local saved = self:_save_state{
        pending = true,
        expected = manifest.version,
        previous = self.version,
        backup = backup,
        package = path,
        installed_at = os.time(),
    }
    if not saved then
        return rollback("更新状态写入失败")
    end

    Log.info(string.format("[Updater] 更新已安装 version=%s backup=%s", tostring(manifest.version), backup))
    return true
end

-- ============================================================
-- 启动自检 / 回滚
-- ============================================================

--- KOReader 启动时调用。
-- @return "updated"  上次替换已生效（新版本正在运行），备份已清理
--         "mismatch" 上次替换没生效，备份仍保留，可提示用户或回滚
--         nil        没有待确认的更新
function Updater:startup()
    local state = self:_load_state()
    if not state.pending then
        self:cleanup_artifacts()
        return nil
    end

    if tostring(state.expected) == tostring(self.version) then
        if state.backup then H.delete_dir(state.backup) end
        if state.package then self:_remove_package(state.package) end
        self:_save_state{}
        self:cleanup_artifacts()
        Log.info("[Updater] 更新已确认，回滚点已清理 version=" .. tostring(self.version))
        return "updated"
    end

    -- 还是旧版本。最常见的解释是「装完还没重启」——此时插件目录里已经是新版，
    -- 只是内存里跑的还是旧代码，下次真正重启就会匹配上。所以这里**不急着回滚**，
    -- 只累加次数；UI 层拿到 attempts >= 2 才提示用户（一次很可能是还没来得及重启）。
    state.attempts = (tonumber(state.attempts) or 0) + 1
    local protected = {}
    if state.backup then protected[state.backup] = true end
    if state.package then protected[state.package] = true end
    self:cleanup_artifacts(protected)
    self:_save_state(state)
    Log.warn(string.format("[Updater] 更新未生效 expected=%s running=%s attempts=%d",
        tostring(state.expected), tostring(self.version), state.attempts))
    return "mismatch", state.attempts
end

--- 是否有可回滚的备份（供 UI 决定要不要显示「回滚」入口）。
function Updater:pending_backup()
    local state = self:_load_state()
    if state.pending and type(state.backup) == "string" and H.dir_exists(state.backup) then
        return state.backup, state.expected, state.previous
    end
    return nil
end

--- 放弃这次更新：把备份还原回插件目录。
-- 只在 startup() 返回 "mismatch" 时有意义（重启后跑的仍是旧版，说明替换无效）。
function Updater:rollback()
    local backup, expected = self:pending_backup()
    if not backup then return nil, "没有可回滚的备份" end
    if not self.plugin_root or self.plugin_root == "" then
        return nil, "无法定位插件目录"
    end

    local saved_config = read_file(self.plugin_root .. "/config.lua")
    H.delete_dir(self.plugin_root)
    local restored, err = copy_tree(backup, self.plugin_root)
    if not restored then
        return nil, "回滚失败：" .. tostring(err) .. "；备份保留在 " .. backup
    end
    if saved_config then
        write_file(self.plugin_root .. "/config.lua", saved_config)
    end
    H.delete_dir(backup)
    self:_save_state{}
    Log.info("[Updater] 已回滚到 " .. tostring(self.version) .. "（放弃 " .. tostring(expected) .. "）")
    return true
end

Updater.version_newer = version_newer
Updater.clean_notes = clean_notes
Updater.UPDATE_CHANNEL = UPDATE_CHANNEL
Updater.MANIFEST_URLS = MANIFEST_URLS

return Updater
