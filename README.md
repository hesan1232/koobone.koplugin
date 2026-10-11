# Koobone 漫画插件

在 KOReader 中阅读 Koobone 漫画库的插件。支持书架浏览、漫画下载缓存、阅读进度云端同步、多维度排序和智能预下载。

## 功能列表

- **书架浏览** — 两层结构：系列列表 → 卷列表，支持搜索与刷新
- **三种排序** — 按更新时间 / 按名称 / 按最后阅读时间，设置自动持久化
- **漫画下载** — 带实时进度条、断点续传（Range 头支持）、多策略自动切换
- **EPUB 缓存** — 下载后自动解压解析，LRU 策略清理过期和超缓存
- **阅读进度同步** — 自动拉取云端进度、定时上传、手动拉取/覆盖选项
- **智能预下载** — 打开漫画后后台静默预下载后续 N 卷，零弹窗干扰
- **后台运行** — 下载可转入后台继续，不阻塞阅读
- **KOReader 原生打开** — 下载完成后直接用 KOReader 内置 EPUB 阅读器打开

## 安装方法

1. 将 `koobone.koplugin` 文件夹放入 KOReader 插件目录：
   ```
   /mnt/onboard/.koreader/extensions/koobone.koplugin/
   ```
2. 重启 KOReader 或重新扫描插件即可。

### 从旧版升级到 v1.3.2

v1.3.2 同样是纯代码修复版（删除死代码 + 清理未使用的局部变量），**无需任何手工迁移**：直接覆盖插件目录后重启 KOReader 即可。

> 注意：`X-KB-FROM` 请求头中的客户端版本号会随之变为 `koobone.koplugin/1.3.2 (设备型号)`。

### 从旧版升级到 v1.3.1

v1.3.1 同样是纯代码修复版，**无需任何手工迁移**：直接覆盖插件目录后重启 KOReader 即可。
唯一行为变化是**网络瞬时错误会自动退避重试 3 次**（弱网下打开书架不再一次失败就报「拉取失败」）。

> 注意：`X-KB-FROM` 请求头中的客户端版本号会随之变为 `koobone.koplugin/1.3.1 (设备型号)`。

### 从旧版升级到 v1.3.0

v1.3.0 为纯代码修复版，**无需任何手工迁移**：配置、缓存、下载目录与阅读进度均向后兼容，
直接覆盖插件目录后重启 KOReader 即可。

> 注意：`X-KB-FROM` 请求头中的客户端版本号会随之变为 `koobone.koplugin/1.3.0 (设备型号)`。

### 从旧版升级到 v1.2.1

v1.2.1 已原生整合此前社区维护的 `koobonefixes.koplugin` 所有补丁：

- 封面文件名 VFAT 安全化（`H.cover_filename_for`）
- 书架重建后 tap 队列崩溃守卫（`Button.onTapSelectButton` 守卫）
- 延迟样式更新崩溃守卫（`ReaderStyleTweak.updateCssText` 守卫）
- 异步刷新父进程内存同步（`Bookshelf:apply_refresh_result`，替代 `debug.setupvalue` hack）

升级后请**删除 `koobonefixes.koplugin` 目录**：
- 主插件已包含所有修复，companion plugin 已无存在必要
- koobonefixes 用 `debug.setupvalue` 操作 upvalue，依赖变量名匹配，脆弱易碎
- koobonefixes 的 `H.join_path` 全局 hook 会让所有路径拼接调用走拦截，有副作用
- 虽然双重安装不会冲突（守卫标记互斥，叠加结果一致），但保留它只会增加无谓开销

## 使用流程

```
KOReader 菜单 → 插件 → Koobone 漫画 → 打开书架
  │
  ├─ 首次打开：自动加载本地缓存，同时后台静默刷新
  ├─ 系列列表：选择系列 → 进入卷列表
  │   └─ 左上角菜单：刷新书架 / 排序方式 / 搜索
  │
  ├─ 卷列表（进入某个系列后）：
  │   └─ 左上角菜单：返回书架 / 刷新目录 / 排序方式 / 搜索
  │
  ├─ 点击卷 → 三种状态：
  │   ├─ 已下载：直接用 KOReader 打开 EPUB
  │   │   └─ 后台自动预下载后续 N 卷
  │   ├─ 未下载：弹出下载进度对话框
  │   │   ├─ 进度实时显示（当前大小 / 总大小）
  │   │   ├─ 支持取消 / 后台运行
  │   │   └─ 完成后自动打开
  │   └─ 下载中：提示该卷正在下载中
  │
  └─ 阅读界面：
      ├─ 顶部：返回 / 书名
      ├─ 中部：漫画图片（高度优先铺满）
      └─ 底部：上一章 / 进度条 / 下一章
```

## 书架排序与搜索

书架的**两个层级**（系列列表 / 卷列表）左上角都有菜单按钮，菜单里各有「排序方式」和「搜索」。
交互参考「开源阅读」插件的书架菜单。

| 层级 | 菜单项 | 说明 |
|------|--------|------|
| 系列列表 | 刷新书架 | 强制重新拉取系列列表（联网） |
| 系列列表 | 排序方式 | 按最后阅读 / 按更新时间 / 按名称 |
| 系列列表 | 搜索 | 按 **系列名或作者** 筛选 |
| 卷列表 | 返回书架 | 回到系列列表 |
| 卷列表 | 刷新目录 | 强制重新拉取该系列的卷列表 |
| 卷列表 | 排序方式 | 按卷序 / 按名称 / 按更新时间 |
| 卷列表 | 搜索 | 按 **卷名** 筛选 |

**排序**：同一个键再点一次就翻转正/倒序，当前生效的键后面标 `✓`，按钮上直接显示方向：

```
按最后阅读（倒序）
按更新时间（倒序）
按名称（正序）  ✓
```

各键的默认方向：名称正序，时间 / 最近阅读倒序；切换排序键时会恢复该键的默认方向。
排序键与方向都会记住（写入 `koobone.lua`，重启后仍生效）。

**搜索**：输入关键字按「确定」后，列表只保留匹配项，标题栏变成 `Koobone 书架 [关键字]`；
留空再确定 = 清除搜索。匹配为**大小写不敏感的子串**，关键字里的 `.`、`(` 等字符按字面处理
（不是正则）。搜索后若一条都没匹配上，会提示并**保留原列表** —— 否则菜单会因空列表直接消失，
用户就再也清不掉筛选了。

**两套排序互不影响**：书架排序只作用于系列列表；进入系列后默认仍按
`第1卷 → 第2卷 → …` 的卷序排列，不会因为书架按「更新时间」排就打乱漫画的阅读顺序。
需要时可在卷列表的「排序方式」里单独改。

> 搜索关键字是**当前视图的会话状态**：跟着菜单走（排序、刷新、下载完成后的原地刷新都会保留），
> 关闭书架重新打开会清空；切换层级（进系列 / 返回书架）时也会清除，避免带着系列列表的
> 筛选进到卷列表而看起来「系列是空的」。

## 检查更新

菜单：**Koobone 漫画 → 检查更新**

| 菜单项 | 说明 |
|--------|------|
| **立即检查更新** | 手动检查。有新版会弹出更新说明与「下载并安装」确认框 |
| **自动检查更新** | 开关。开启时每次启动 KOReader 后延迟 5 秒静默检查一次 |
| **检查频率** | 每天 / 每 3 天 / 每 7 天。限流用，避免每次启动都打网络 |
| **安装完成后** | 询问是否重启（默认）/ 自动重启 / 稍后手动重启 |
| **当前版本** | 只读展示 |
| **回滚上次更新** | 仅在「装了但重启后没生效」时出现 |

**关于安装**：升级会替换 `plugins/koobone.koplugin/` 下的全部文件，但 **`config.lua` 会被保留**
（API Key 不用重填）。整个过程分四步，每一步失败都能安全收场：

1. 下载后**强制校验 SHA-256**（清单里带摘要，对不上直接拒绝安装）；
2. 解压到暂存目录，校验包结构（必须只含一个 `koobone.koplugin` 根目录）与**包内版本号**
   （必须与清单一致）；
3. 备份当前插件目录 → 替换文件 → 恢复 `config.lua`；中途任何一步失败都会自动回滚；
4. 重启 KOReader 后，插件启动时比对「期望版本 vs 实际运行版本」——一致才算更新成功并清掉
   回滚点；不一致则保留备份，菜单里出现回滚入口。

**关于网络**：更新源是 GitHub Release。国内直连 `github.com` / `raw.githubusercontent.com`
通常不通，插件会自动改用镜像（ghfast.top / gh-proxy.com / ghproxy.net）。镜像只影响下载速度，
**不会影响安装内容** —— 下载完仍然强制校验 SHA-256。自动检查只在**已经联网**时进行，绝不主动开 WiFi。

**关于兼容性**：解压走 KOReader 自带的 `ffi/archiver`（纯 Lua），SHA-256 也是自带的纯 Lua 实现，
因此**不依赖设备上有 `unzip` / `sha256sum` 命令**（Kindle 的 busybox 就没有）。

## 与第三方桌面插件共存（首页手势）

**现象**：首页（文件管理器）里用手势打开书架没反应，但从菜单点「书架」一切正常。

**原因**（KOReader 上游机制，已逐行核对）：`UIManager:sendEvent` 只把派发事件交给窗口栈
最上面那个控件；它不消费时，才继续交给「该控件的 `active_widgets`」与「标了
`is_always_active` 的控件」。而 `FileManager` 自身既不是 `is_always_active`，插件也没被登记
进它的 `active_widgets` —— 于是**只要有控件盖在首页之上**（例如第三方桌面类插件），
`Dispatcher` 派发到本插件的动作就永远送不到。

菜单项不受影响：它是回调**直接调方法**，不走事件派发 —— 这个不对称就是判别式。

**处理**：插件启动时把自身挂进 `ui.active_widgets`（上游留的正是这个口子 ——
`registerModule(name, module, always_active)` 的第三个参数，注释写着
"to get events even when hidden"）。挂进去的是一个只放行本插件自有事件的**桥**：
触摸 / 按键等输入事件一概不转发，因此不改变任何既有行为。

**边界**（这两条绕不过去，属上游 `sendEvent` 本身的设计）：

1. 遮挡控件**主动消费**了事件（返回 `true`）—— 那是它的正当行为，不该绕过；
2. 遮挡控件在事件链上**抛错** —— `sendEvent` 里 `if top_widget:handleEvent(event) then`
   没有 `pcall` 保护，异常会让整条派发链中断（表现为 KOReader 崩溃/重启），
   此时任何插件都收不到。这种情况要修的是那个控件本身（或先禁用它）。

排查提示：先看 `crash.log` 有没有 `Failed to initialize` 或指向别的插件的崩溃栈；
另外 KOReader 的手势设置分**两套**（`gesture_fm` 首页 / `gesture_reader` 阅读界面），互不通用。

## 配置说明

进入 KOReader 菜单 → 插件 → Koobone 漫画 → 设置：

| 配置项 | 说明 |
|--------|------|
| **服务器地址** | Koobone API 地址（默认 `https://koobone.com`） |
| **API Key 设置** | 在 [koobone.com](https://koobone.com/) 官网登录后，进入"个人设置"页面获取 API Key，填入此处即可 |
| **排序方式** | 书架（系列列表）默认排序：最后阅读 / 更新时间 / 名称。可在书架左上角菜单里随时改，并可翻转正/倒序 |
| **预下载卷数** | 打开漫画后自动预下载的后续卷数 |
| **缓存大小上限** | EPUB 缓存最大占用空间（MB）；超出后按最久未访问（LRU）清理到 80% |
| **自动清理缓存** | 是否自动清理 EPUB 缓存（过期 48 小时、或超上限）。默认开启 |
| **进度上传间隔** | 阅读时自动上传进度的间隔（秒） |
| **下载封面** | 是否下载漫画封面到本地 |

### API Key 获取步骤

1. 浏览器打开 [https://koobone.com/](https://koobone.com/) 并登录账号
2. 进入"个人设置"页面（通常位于右上角用户菜单内）
3. 找到"API Key"或"接口密钥"项，复制显示的字符串
4. 回到 KOReader：菜单 → 插件 → Koobone 漫画 → 设置 → **API Key 设置**，粘贴保存

API Key 通过 `X-KB-INFO` 请求头直传服务端鉴权，无需配置 Cookie/Session。如果未配置 API Key，打开书架时会提示"未配置 API Key，请先在 Koobone 设置中填写"。

## 技术架构

### 异步下载与进度追踪

```
主进程                         子进程（fork）
  │                               │
  ├─ 创建 DownloadProgress 对话框 │
  ├─ 生成 IPC 文件路径             │
  │   └─ progress.json            │
  │   └─ cancel.flag              │
  │                               │
  ├─ Async.run(work_func)  ──────→│ download_epub_file(vol)
  │   │                           │   └─ ensure_epub()
  │   │                           │       └─ _do_http_download_with_progress()
  │   │                           │           每 0.5s 写入 → progress.json
  │   │                           │           检查 cancel.flag
  │   │                           │
  │←──── 回调 on_done ────────────│
  │                               │
  ├─ 轮询 UIManager:scheduleIn   │
  │   每 0.5s 读取 progress.json  │
  │   更新对话框 UI                │
```

### 模块结构

| 模块 | 职责 |
|------|------|
| `main.lua` | 插件入口、菜单注册、协调各子模块 |
| `settings.lua` | LuaSettings 持久化配置（auth/shelf/cache/reader） |
| `client.lua` | HTTP API 客户端（卷列表、卷详情、EPUB 下载） |
| `auth.lua` | 登录鉴权、Cookie 管理 |
| `download.lua` | EPUB 下载、断点续传、IPC 进度、LRU 缓存清理 |
| `reader.lua` | 自建阅读 UI（图片展示、翻页、进度回调） |
| `progress.lua` | 云端进度同步（拉取/上传） |
| `bookshelf.lua` | 书架数据管理（系列分组、排序、本地缓存） |
| `shelf_view.lua` | 书架 UI 渲染（系列/卷两层列表） |
| `async.lua` | 基于 ffiutil.runInSubProcess 的异步执行 |
| `helper.lua` | 工具函数（路径、HTTP、文件操作） |
| `state.lua` | 运行时状态（当前漫画、下载进度、书架缓存） |

### Lua 5.1 兼容性

插件运行于 KOReader 的 Lua 5.1 / LuaJIT 环境，已确认：

- `os.execute` 返回值兼容 5.1（number）和 5.2+（多值）
- `table.unpack` 使用 `unpack or table.unpack` 双回退
- 不使用 `//` 整数除法、`utf8` 库、`bit32` 库、`_ENV`、`goto`、`__pairs` 等 5.2+/5.3+ 特性
- `loadstring` / `load` 编译兼容

## 发布流程

插件的「检查更新」读的是仓库 `main` 分支根目录的 `update.json`，包则在 GitHub Release 上。
两者都由打包脚本一次生成：

```bash
# 1. 改代码，并把 koobone/info.lua 的 version 改好（版本号只有这一个来源）
# 2. 打包 + 生成清单（版本号、包大小、SHA-256 全部自动计算）
python .workbuddy/tools/pack_plugin.py D:/webProgram/project/koobone.koplugin
# 3. 提交（注意 update.json 要和代码一起进 main 分支，否则客户端读不到）
git add -A && git commit -m "v1.5.0"
git tag v1.5.0
git push origin main --tags
# 4. 在 GitHub 上按 v1.5.0 建 Release，上传 koobone.koplugin.zip
```

脚本会自动把用户的 `config.lua` 排除在包外（含 API Key，绝不发布），zip 内保留一层
`koobone.koplugin/` 根目录，并且**按字节写入、完整保留源文件行尾**。

> ⚠️ 打包前确认没有未提交的源文件 —— `pack_plugin.py` 是从**工作目录**读取的，
> 而别人 `git clone` 拿到的是**已提交内容**。两者不一致时，更新包会比仓库多/少文件。

## 更新日志

### v1.5.0（2026-10-11）

**新增：书架两级视图的「排序」与「搜索」**（交互参考「开源阅读」插件）

- **排序**：系列列表（按最后阅读 / 更新时间 / 名称）与卷列表（按卷序 / 名称 / 更新时间）；
  同一个键再点一次翻转**正序 / 倒序**，当前生效的键标 `✓`，按钮直接显示方向。
- **搜索**：菜单内输入关键字（大小写不敏感子串，非正则）；系列匹配 **名称 + 作者**，
  卷匹配 **卷名**；标题栏显示 `[关键字]`，留空 = 清除。
- **两套排序互相独立**：书架按「更新时间」排**不会**打乱卷目录「第 1 卷 → 第 2 卷」的阅读顺序。
- 切换视图（进系列 / 返回书架）会清空搜索关键字；无匹配时提示并**保留原列表**。
- **顺带修复**：此前切换视图时**标题栏不刷新**（上游 `title_bar` 只在初始化 / `setTitle()`
  时重建，直接改 `menu.title` 无效），现在会正确更新。

---

以下为详细说明：

- **排序方式**：系列列表与卷列表的左上角菜单都有「排序方式」。
  - 系列列表：按最后阅读 / 按更新时间 / 按名称
  - 卷列表：按卷序 / 按名称 / 按更新时间
  - 同一个键再点一次翻转**正序 / 倒序**，当前生效的键标 `✓`，按钮上直接显示方向。
  - 排序键与方向写入 `koobone.lua`，重启后仍生效；**两套排序互相独立** ——
    书架按「更新时间」排**不会**打乱卷目录「第 1 卷 → 第 2 卷」的阅读顺序。
- **搜索**：两个层级的菜单都有「搜索」。输入关键字后列表只保留匹配项，标题栏显示
  `Koobone 书架 [关键字]`；留空再确定 = 清除搜索。匹配是**大小写不敏感的子串**，
  关键字里的 `.`、`(` 等字符按字面处理（不是正则）；系列匹配**系列名 + 作者**，
  卷匹配**卷名**。若一条都没匹配上，会提示并**保留原列表** ——
  否则空列表会让菜单直接消失，筛选就再也清不掉了。
- **切换视图会清空搜索关键字**（进系列 / 返回书架），避免带着系列列表的筛选
  进到卷列表而看起来「系列是空的」。
- **顺带修复**：此前切换视图（进系列 / 返回书架）**标题栏文字不会刷新** ——
  上游 `Menu` 的 `title_bar` 只在初始化与 `setTitle()` 时重建，直接改 `menu.title` 是无效的。
  现在标题通过 `switchItemTable(new_title, ...)` 更新，切换视图时标题会正确变化。

改动文件：`settings.lua`（排序方向 / 卷排序设置）、`bookshelf.lua`（排序支持方向与卷排序键）、
`shelf_view.lua`（菜单、搜索、过滤、标题）。

### v1.4.0（2026-10-11）

**新增：插件内「检查更新」与一键升级**（设计参考觅阅 miuread）

- **检查更新**：菜单「Koobone 漫画 → 检查更新 → 立即检查更新」。从 GitHub Release 的
  `update.json` 读最新版本号做语义化比对。清单里同时带 4 个下载地址（GitHub 原址 + 3 个国内
  镜像），直连不通时自动换下一个。
- **自动检查**：启动 5 秒后静默检查一次，默认 24 小时最多一次（可关、可改频率），同一个新版本
  只提醒一次。**只在已联网时检查**，绝不主动开 WiFi。
- **下载与安装**：下载后强制校验 SHA-256 → 解压到暂存目录并校验包结构与包内版本号 →
  备份当前插件 → 替换 → 恢复用户配置。任何一步失败都自动回滚到旧版本。
- **安装后重启**：可选「询问（默认）/ 自动重启 / 稍后手动」。重启后插件启动时比对
  「期望版本 vs 实际运行版本」，一致才算更新成功并清掉回滚点；不一致则保留备份并给出回滚入口。
- **保留用户配置**：`config.lua`（含 API Key）在升级时被完整保留。更新包本身也禁止含
  `config.lua` —— 发布包不该带凭证，真带上了直接拒绝安装。
- **零外部命令依赖**：解压用 KOReader 自带的 `ffi/archiver`（纯 Lua），SHA-256 也是纯 Lua 实现，
  不依赖设备上的 `unzip` / `sha256sum`。

新增模块：`koobone/digests.lua`（SHA-256）、`koobone/updater_http.lua`（清单拉取与包下载）、
`koobone/updater.lua`（清单校验 / 下载 / 备份替换 / 回滚 / 启动确认）、
`koobone/updater_ui.lua`（菜单与流程编排）；`helper.lua` 新增 `H.unzip_file`。

**同时修掉两个会让功能「静默失效」的问题**

- **`redirect` 参数让所有 HTTPS 更新请求在发出前就失败**：更新器给请求传了
  `redirect = true`，而 LuaSec 的 `ssl/https.lua` **不支持自动重定向** ——
  `elseif url.redirect then return nil, "redirect not supported"`，请求根本发不出去。
  设备日志里就是 `[Updater] 清单请求失败 … redirect not supported`（自动检查因此一直失败）。
  改为手动跟随跳转（上限 5 次）。
- **`init()` 里任何一处抛错会弄哑整个插件**：上游 `PluginLoader:createPluginInstance`
  用 `pcall(plugin.new, plugin, attr)` 包住构造，而 `Widget:new` 内部就会调 `init()` ——
  也就是说 `init()` 抛错时**插件实例根本不会被创建**，现场只留一行
  `logger.err("Failed to initialize", ...)` 日志。后果是主菜单与手势动作一起消失，而
  `Dispatcher:execute` 查不到动作名时**静默跳过**，用户看到的就是「首页手势点了没反应」。
  现拆成 `init + _init_modules`：动作注册最先跑且不依赖任何模块，模块构造整段 `pcall`，
  失败只降级为「插件不可用但实例仍在」。
- **首页被第三方桌面插件遮挡时手势也能生效**：把手势动作事件挂进 `ui.active_widgets`
  （详见「与第三方桌面插件共存」一节）。

### v1.3.3（2026-10-11）

**第四轮复查 · 清理 / 重复 / 性能**（无用户可见功能变更）

- **删除整模块死代码**：`koobone/i18n.lua`（228 行、约 170 条翻译表）。它在 `main.lua` 里
  `safe_require` 之后**全仓零 `I18n.*` 调用** —— 界面文案一直走 KOReader 的 gettext
  （`shelf_view.lua` 的 `_t`），这个自建翻译层从未接线。如日后要做英文界面，需重新接入
  并把硬编码中文换成 `I18n.tr`，属独立议题（旧文件在 git 历史与第三轮清理的备份里）。
- **清理死变量 / 死分支 / 悬挂钩子**：`http_downloader` 的 `remote_content_length`（在 sink 内被读取，
  而唯一赋值发生在请求返回**之后** → 分支恒假）+ 未使用的 `response_headers` + 随之变成死代码的
  `extract_content_length`；`download.lua` 的 `cancel_requested`（无读取方，真正生效的是 IPC
  `cancel.flag`）与 `_queue_processing` / `_queue_listeners` 两个**快照**（布尔快照永远停在初始值）；
  `queue.lua` 的队列通知子系统（`_queue_listeners` 无生产者、`_notify` 恒遍历空表、
  `get_status` 仅被 `_notify` 调用）；`shelf_view.lua` 的 `check_download_state`（零调用）、
  `ShelfMenu:onPageChanged` / `shelf_close_cb` / `_shelf_menu_closed_callback`，以及
  `on_page_changed` / `_suppress_page_callback` 这对**无任何赋值**的页面回调钩子
  （`Menu` 基类并没有 `onPageChanged`，被覆盖的 `Menu.onPageChanged(...)` 其实是 nil 调用）。
- **重复常量归一**：`DESKTOP_UA` 原本在 `client.lua` / `http_downloader.lua` 各一份，`koobone.lua`
  里还有第三份且版本不同（Chrome/150，**全仓无人读取**）→ 统一为 `H.DESKTOP_UA`（值保持
  Chrome/120 不变：UA 属对外行为，不顺手改）；`http_downloader` 中零调用的 `M.clamp` /
  `M.format_size`（`download_progress.lua` 有自己的同名 local 实现）删除。
- **未消费配置**：`shelf.per_page` 删除（书架每页条数实际由 `shelf_view.lua` 的
  `items_per_page = 8` 决定，与它无关）。
- **版本号回退字面量对齐**：`main.lua` 的 fallback 由 `"1.2.0"` 改为与其余 5 处一致的当前版本。
- **性能**：`helper.json_decode` / `json_encode` 的 `pcall(require, "json")` 改为模块级惰性缓存 ——
  它们处在「主进程每 0.3s 读一次进度文件」的 IPC 热路径上。

> 有意保留：`state.lua` 的 15 个「未接线访问器」（与状态字段一一对应，成组才有意义）、
> `Async.active_count`、`Progress:manual_pull`、`Bookshelf:download_cover_file` / `Client:get_binary`
> 等**动态派发**调用点（静态工具看不见，非死代码）。

### v1.3.2（2026-10-10）

**死代码清理（删除 43 个零调用函数 / 净减 772 行，纯删除无行为变更）**

- 用静态检查重算不可达集合后**逐个人工 grep 复核**（该工具对动态派发有误报），删除 43 个零调用函数，
  例如 `auth.is_logged_in`、`client.get_user_info` / `header_value`、`download.clear_queue` / `_cache_key`、
  `helper.download_file` 系列、`logger.clear_log`、`progress.destroy` / `update_page`、
  `settings.merge_tables` 等。
- **保留**工具看不见但确实可达者：`Async.active_count`（与局部变量重名）、
  `download_cover_file` / `get_binary` / `trigger_cover_download`、
  `ShelfView_show|update|close|refresh_current`（经 `main.lua` 动态派发）、
  `Progress:manual_pull`（有意保留的手动入口）。
- 另清理未使用的局部变量：`http_downloader.lua` 的 `ltn12` / `ok_ssl,ssl` / `ok_tcp,tcp`，
  `main.lua` 的 `TextViewer`。
- `koobone/state.lua` 里 15 个「未接线访问器」**成组保留**并在注释中列出，供后续按需接线或成组删除。

### v1.3.1（2026-10-10）

**修复：写盘 / 取消信号的返回值此前无人检查（6 处）**

- **取消信号可能写不出去，而调用方仍以为「已取消」** — `http_downloader.ipc_write_cancel` 用 `pcall` 包住写
  `_cancel.flag` 的整个流程并丢弃结果，`Download:cancel` 又无条件置 `signalled = true`。于是
  「磁盘满 / 句柄异常」时用户点了取消、界面回「已取消」，**子进程照跑到底**。现在
  `ipc_write_cancel` 返回是否确认写入、`ipc_send_cancel` 原样透传，`cancel` 只在**确实写入**时才算命中，
  失败记 warn 并如实返回 false。
- **进度 IPC 文件写入失败静默丢失** — `http_downloader.ipc_write_progress` 同理：写失败时 `os.rename`
  仍可能成功，父进程会读到一个空 / 截断的进度 JSON（表现为进度条不动）而没有任何线索。现检查
  `write`/`close`、失败时清掉 `.tmp`；告警只打一次（本函数按进度 tick 高频调用，避免刷爆日志）。
- **书架缓存原子写** — `bookshelf.save_shelf_cache` 此前无条件 `rename`：写入失败时会把一个
  **截断的 Lua 源码缓存**换上去，而该缓存由 `loadfile` 直接执行 → 下次启动解析失败，书架回到空状态。
  现写入失败即删 `.tmp` 并返回 false。
- **封面写入** — `bookshelf.download_cover_file` / `download_covers` 补 `write`/`close` 检查：
  原有的「写后 size == 0」只能抓住完全为空，抓不住**写了一半**（半张封面会被显示，且文件已存在不会重下）。
- **日志写入**（`logger.lua`）— 补 `write` 返回值检查：失败时关闭并丢弃句柄（下次调用自动重开），
  否则之后每条日志都对着一个坏句柄写、全部静默丢失。

**新增：网络错误分级重试（`client.lua`）**

- 移植 `reading.koplugin/reading/webdav.lua` 的 `RETRY_CONFIG` / `is_retryable_code` / `get_retry_delay`。
  此前 **API 层完全没有重试**：一次瞬时连接失败或瞬时 5xx 就会把异常抛给调用方，而
  `bookshelf:refresh` 是「一次失败即中止」—— 弱网下打开书架＝「书架为空 / 拉取失败」。
- 分级判据：`nil`（连接被重置 / 异常）、`5xx`、`408`、`429` → 指数退避重试（1s → 2s，上限 4s，共 3 次）；
  `4xx`（401/403/404…）与业务错误 → **立即停**，不再白等。
- 每次重试**重建 sink**（失败尝试的响应体已写入 sink，沿用会把两次响应拼在一起 → JSON 解析必然失败）。
- 重试耗尽后若最后一次是异常，原样重新抛出 —— 调用方原有「连接失败会 error」的行为不变。
- ⚠️ 调用点全部在 `Async.run` 子进程内（`bookshelf:refresh` / `progress:query_vol_info` / 封面下载），
  因此 `socket.sleep` 不会阻塞 UI 线程；EPUB 下载路径走 `http_downloader` 直连，不经过本层，两者不叠加。

### v1.3.0（2026-10-10）

本版集中修复了「进度同步」「下载取消」两条主链路上此前**实际失效**的问题，并补齐取消/会话的并发安全。

**修复（此前功能实质不可用）：**

- **阅读进度同步整体空转** — `reader.lua` 调用了 `progress.lua` 中并不存在的 `update_local_progress` / `push_to_cloud` / `last_page` / `total_pages`。现已对齐 API：`progress.lua` 新增 `_sync_public()` 并重写 `end_session(cb, {skip_upload})`（原实现先置 `_destroyed`，导致关闭时推送变成空操作）；`reader.lua` 新增 `Reader:get_progress()` 与 `current_vol` 只读视图，`shelf_view` 改读该视图
- **手动上传云端进度永远失败** — `client:upload_progress` 不存在（被 `shelf_view` 调用）。已新增薄封装桥接到 `report_read_page`
- **下载去重/排队失效** — `queue.is_enqueued` 读取了未定义的 `state.pending`，恒返回 false。改读实名数组 `state._download_queue`
- **断点续传检测可能报错** — `http_downloader.lua` 裸用 `lfs` 却未 require。已补 `pcall(require, "libs/libkoreader-lfs")`，并修正 `lfs.attributes(path, "size")` 的返回值用法
- **取消下载不通知子进程** — `Download:cancel` 不存在。现新增统一入口（出队 + 写 `_cancel.flag` + 标 `cancel_requested`），子进程读循环内检测后真正终止；同时删除两条并行的旧下载路径与一批死代码
- **子进程「无输出」被误判为失败** — `Async` 原先把「退出码 0 但无输出」当失败，会让已经成功的操作弹出「加载失败」。现按「无输出 = 无返回值的成功」处理
- **`handle.cancel` 是死代码** — 现已真正接线：新增模块级活动登记表与 `Async.cancel_all()` / `Async.cancel_tag(tag)`，并在「正常完成 / 取消 / 超时」三条终结路径上退登记；新增 `opts.on_cancel`，供带 loading 的流程在取消时关闭弹窗（取消后 `on_done` 不再执行，否则界面会永久卡 loading）
- **EPUB 缓存 LRU 清理整条链路是死的** — `Download:_lru_cleanup` 与它唯一的实现 `H.lru_cleanup`（68 行）全仓库零调用，`cache.lru_cleanup_enabled` 只写不读 —— README 承诺的「LRU 策略清理过期和超缓存」从未发生，`EPUB_CACHE_DIR` 只会无限增长。现已接线：**下载成功后**触发一次 + **启动后延迟 10 秒**触发一次（内部 1 小时频率门限，批量下载不会反复扫盘），并在「下载设置」里补上**缓存大小上限**与**自动清理缓存**两个开关（此前 `cache_max_size_mb` 只能手改 `config.lua`）
- **打开漫画 / 换卷时进度同步被误终止** — `onCloseWidget` 此前用 `self.ui.document` 判断「是不是阅读器关闭」，而该字段在此时恒为 nil。改为**会话归属**判定（`Reader:claim_session(ui)` 在 `onReaderReady` 认领 + `is_session_owner(ui)` 比对）
- **换卷时上一卷的最后进度静默丢失** — `open_comic` 现在先对上一卷 `close_reader(true)` 再开启新会话

**新增：**

- **页码实时更新** — 新增 `onPageUpdate` / `onPosUpdate` 钩子，页码不再只由 30s 周期同步（短时阅读退出时此前推的是起始页）。注意 `onPosUpdate` 的第二参数才是页码，滚动模式只发该事件
- **下载健壮性** — 下载 sink 增加 `write` 返回值检查（磁盘写满时不再落盘截断却报成功）与速率停滞检测（`STALL_MS` / `MIN_RATE`，识别「还在滴数据但慢到不可用」）；`sink_err_msg` 优先于 HTTP 状态码上报，避免真因被含糊的 `HTTP nil` 掩盖
- **防串号令牌** — 会话代次（`Reader._session_gen` / `Progress._session_gen`）与视图令牌（`shelf_view._view_token` / `_progress_dialog_token`），避免「打开界面 + 异步回填」被上一轮结果覆盖

**顺带修正：**

- `Log.err` → `Log.error`、`Log.flush` → `Log._flush`（方法名写错，调用即报错）
- `main.lua` 中 `ok_Async` 未定义 → `onShowToc` 异步分支永不可达
- `state.lua` 裸用 `UIManager` 未 require → 3 秒聚合写盘从未生效
- `onGesture` 里调用不存在的 `showSettings()` 会崩掉整个 KOReader（改可选钩子 + pcall 保护）
- 版本号统一为 `koobone/info.lua` 单一来源，其余 4 处回退字面量同步更新（此前停留在 `0.2.0`）
- 「关于」菜单里的版本号此前硬编码为 `v0.3.0`（第 5 处版本字面量）→ 改为从 `koobone/info.lua` 读取

### v1.2.1（2026-09-13）

**修复：**

- **刷新书架无效** — 修复 Async.run 子进程对 `SERIES_MEM_CACHE`/`SERIES_VOLS_MEM` 的修改不反映到父进程的问题。新增 `Bookshelf:apply_refresh_result(result)` 方法，在父进程 on_done 回调里用子进程返回的 series + all_vols 重建父进程内存缓存。此前需要禁用再启用插件才能看到刷新结果
- **封面文件名 VFAT 不兼容** — 修复 Kindle VFAT 文件系统不接受 `:` 等字符导致封面下载报 Invalid argument 的问题。`series.id` 可能是 `KMOE:27464` 形式，直接用作文件名会在 Kindle 上失败。新增 `H.cover_filename_for(fmd)` 统一生成封面文件名，经过 `safe_filename` 处理非法字符
- **书架重建后 tap 队列崩溃** — 修复封面下载失败触发 UI 重建后，队列里残留的 tap 事件访问已释放按钮的 `dimen` 字段导致 `button.lua:415 attempt to index field 'dimen' (a nil value)` 崩溃。新增 Button.onTapSelectButton 守卫，dimen 缺失时跳过 unsafe painting 但仍执行 callback
- **延迟样式更新崩溃** — 修复 `patchReaderUI` 里 `scheduleIn(2.0)` 触发的 `updateCssText(true)` 可能在 ReaderUI 关闭后才执行导致 stale 引用崩溃。新增 ReaderStyleTweak.updateCssText 守卫，`self.ui` 或 `self.ui.document` 为 nil 时跳过

**新增：**

- **全局卷目录预填** — `bookshelf:refresh` 拉取系列列表时并行预拉全局 `vol_list.php`，按 `vol_series` 字段分组写入 L1 内存缓存 + L2 state 目录缓存。用户点进任何系列时直接命中缓存秒开，无需等待 API 返回
- **EPUB 文件命名规范化** — 下载文件改为 `{系列名}/{vol_name}.epub` 目录结构，同一系列的卷集中在一个文件夹下，旧版 `{file_md5}.epub` 文件自动 rename 迁移到新位置

**重构：**

- **术语统一** — 代码标识符与 UI 文案统一改为"卷"概念：`chapter_index_cache` → `vol_index_cache`，`getDownloadedChapters` → `getDownloadedVols`，UI 文案"章节目录"→"卷目录"、"预下载章节数"→"预下载卷数"
- **认证方式调整** — 完全改为 API Key 直传鉴权（`X-KB-INFO` 请求头），移除 Cookie/Session 配置，README 同步更新获取步骤

### v0.2.0（2026-08-10）

**修复：**

1. **下载进度条修复** — 实现文件 IPC 机制解决子进程→父进程进度通信，替代无法跨进程更新 UI 的旧方案
2. **书架闪回修复** — 后台刷新完成后不再强制重渲染书架视图，避免在系列内下载时闪回
3. **排序持久化修复** — `get_series_list` / `get_series_vols` 改用 `settings:get_shelf_sort()` 动态排序，新增"按最后阅读"选项
4. **预下载弹窗修复** — 预下载改为完全静默后台操作，零 UI 干扰
5. **进度条双重大小显示修复** — `message` 字段不再拼接大小信息，统一由 `download_progress.lua` 渲染

**优化：**

- `bookshelf:sort_vols` 简化为仅持久化设置
- 移除 `reader.lua` 中引用不存在模块的 `_on_preload_progress` 回调
- 移除 `state.lua` 中从未调用的 `getShelfSort` / `setShelfSort` 死代码
- `download.lua` 中 `os.execute` 返回值跨版本兼容处理
- `download.lua` 中 `socket.sleep` 替代 `os.execute("sleep")`，避免 fork shell
- 关于对话框和 README 全面重写

### v0.1.0（初始版本）

- 基础书架浏览与搜索
- EPUB 下载与解压解析
- 阅读进度云端同步
- 排序与预下载框架

## 许可证

本插件为 KOReader 社区贡献项目。
