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

## 使用流程

```
KOReader 菜单 → 插件 → Koobone 漫画 → 打开书架
  │
  ├─ 首次打开：自动加载本地缓存，同时后台静默刷新
  ├─ 系列列表：选择系列 → 进入卷列表
  │   └─ 卷列表中可排序、刷新、返回
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

## 配置说明

进入 KOReader 菜单 → 插件 → Koobone 漫画 → 设置：

| 配置项 | 说明 |
|--------|------|
| **服务器地址** | Koobone API 地址（默认 `https://koobone.com`） |
| **登录 Cookie** | 手动设置登录 Cookie（VLIBSID + KBSKEY） |
| **排序方式** | 书架默认排序：更新时间 / 名称 / 最后阅读 |
| **预下载卷数** | 打开漫画后自动预下载的后续卷数 |
| **缓存大小上限** | EPUB 缓存最大占用空间（MB） |
| **进度上传间隔** | 阅读时自动上传进度的间隔（秒） |
| **下载封面** | 是否下载漫画封面到本地 |

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

## 更新日志

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
