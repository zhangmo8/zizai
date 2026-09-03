# 字在 — 产品与架构总览

Status: Draft（v5：两层结构 LibraryHome ⇄ Shell + 分卷 + MCP + 章节字数分布；schema v5）

## 1. 定位

个人自用的沉浸式码字 App。单用户、纯本地、所见即所得。
一句话：**打开就写，所见即所得，写完就走，数据在自己手里。**

## 2. 核心概念

| 术语 | 英文标识 | 定义 |
|---|---|---|
| 库 | `Library` | 单个 SQLite 数据库（`zi-zai.db`），承载全部数据 |
| 笔记本 | `Notebook` | 一个写作项目（书/文集），库内一条记录 |
| 文档 | `Document` | 一章/一篇，库内一条记录，内容为富文本 Delta JSON |
| 字数 | `wordCount` | 文档纯文本：中文字符数 + 英文连续词数 |
| 每日目标 | `NotebookGoal` | 按笔记本独立设定的当日目标，可关闭 |
| 今日增量 | `todayDelta` | 当前笔记本当日累计新增字数，见 §4 增量规则 |
| 沉浸模式 | `FocusMode` | 隐藏侧边栏、工具栏、状态栏的纯编辑状态 |
| 设备 | `Device` | 安装实例（UUID）；快照导出的来源标记 |
| 备份状态 | `BackupState` | idle / uploading / downloading / error（状态栏指示） |
| DB schema 版本 | `schemaVersion` | `PRAGMA user_version`，迁移驱动（见 update.md） |

## 3. 信息架构

```text
字在
├─ 笔记本管理层（LibraryHome）＝ 应用入口
│  ├─ 书架网格/列表（书名 + 章节数 + 总字数，grid/list 切换）
│  ├─ 新建笔记本 + 全局设置入口
│  └─ 启动总是停在这一层
└─ 单书工作区（Shell）＝ 点书进入，声明式门控（currentNotebook）
   ├─ 侧边栏（章节树：分卷分组/拖拽排序/搜索/字数分布/本书设置）
   ├─ 编辑器区（富文本所见即所得 + 常驻格式工具栏 + 选区浮动工具栏）
   │  └─ 状态栏（今日 x/目标 ▎本文 x 字 ▎写作会话）
   ├─ 沉浸模式（复用编辑器区，全屏无 chrome）
   └─ 设置（对话框，桌面） / 设置页（Android）
```

桌面端入口：启动 → **书架（LibraryHome）** → 点书进入工作区。重启总是停在书架，
不自动进上次的书；进某本书时才恢复该书上次打开的章节（`openNotebook` 回溯 last_open）。
Android 端入口：书架 → 点书 → Drawer 工作区（无上次记录则空态引导新建）。

## 4. 数据模型（SQLite，当前 schema v5）

### Schema

```sql
CREATE TABLE notebooks (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  position   INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE documents (
  id          TEXT PRIMARY KEY,
  notebook_id TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
  title       TEXT NOT NULL,
  content     TEXT NOT NULL DEFAULT '{}',  -- Quill Delta JSON
  words       INTEGER NOT NULL DEFAULT 0,  -- 上次保存时纯文本字数快照
  position    INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  status      TEXT NOT NULL DEFAULT 'draft',  -- v3: draft/done/todo 章节状态标记
  notes       TEXT NOT NULL DEFAULT '',       -- v4: 章节备注（不进正文导出）
  volume_id   TEXT                            -- v5: 所属分卷（手动分卷；NULL = 未归卷）
);

CREATE TABLE volumes (  -- v5: 手动分卷真数据
  id          TEXT PRIMARY KEY,
  notebook_id TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  position    INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL
);

CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE stats (
  date  TEXT PRIMARY KEY,   -- '旧版 YYYY-MM-DD；笔记本统计 YYYY-MM-DD::notebookId'
  words INTEGER NOT NULL
);

CREATE TABLE last_open (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  notebook_id TEXT,
  document_id TEXT,
  words       INTEGER NOT NULL DEFAULT 0  -- 该文档上次保存字数
);
```

- settings 键：`theme` / `fontFamily` / `fontSize` / `lineHeight` / `countPunctuation` / `focusDim`
  （焦点暗淡）；笔记本目标使用 `notebookGoal.<notebookId>.enabled/words`；`dailyGoal` 仅作未迁移
  笔记本的默认值。UI 状态键：`outline.open` / `notes.open` / `sidebar.volumeView`（分卷展示/平铺）/
  `library.homeView`（书架 grid/list）/ `docsOrder.<notebookId>`（目录正/倒序）/
  `volume.<notebookId>.name.<n>`（自动分卷重命名）。本地 MCP 见 `mcp.enabled` / `mcp.port`。
- 升级路径：sqflite `onUpgrade` 版本化迁移（`PRAGMA user_version`）；**DB schema 版本号是长期演进基础**——任何加字段/改表必须走迁移链（见 docs/app/update.md §2）；升级前自动备份 db 文件为 `zi-zai.db.bak`（滚动保留 3 份）。
- 云备份数据模型与快照结构见 docs/app/sync.md。
- db 位置：`path_provider` 应用支持目录，桌面与 Android 一致；设置页展示路径。

### 增量规则

编辑器按每次文档变更累计正向字数增加；删除文字不倒扣已完成的今日产出。
保存时将未入库产出累加到 `stats[date::notebookId]`，不同笔记本互不影响；
`documents.words` 仍是当前文档总字数快照。旧版 `stats[date]` 仅保留作快照/同步兼容。

## 5. 模块划分

```text
lib/
├─ main.dart                 # 入口：App 装配、主题、全局错误处理、启动迁移
├─ app.dart                  # MaterialApp、主题选择、两层门控（LibraryHome ⇄ Shell）
├─ core/
│  ├─ models.dart            # Notebook / Document / Settings / NotebookGoal 数据类
│  ├─ db.dart                # SQLite 打开、schema、CRUD、迁移链（user_version，当前 v5）
│  ├─ word_count.dart        # 字数算法（纯函数，输入纯文本）
│  ├─ export.dart            # 文档/整书 → 纯文本、Markdown 导出（单文件/每章一文件）
│  ├─ snapshot_history.dart  # 单文档版本历史：本地 JSON 留底 + 自动留底策略
│  ├─ book_search.dart       # 全书搜索与替换：跨章节匹配 + 全书替换预览
│  ├─ find.dart              # 单文档内查找/替换
│  ├─ outline.dart           # 单文档大纲提取（标题块 → 树）
│  ├─ word_distribution.dart # 章节字数分布（纯函数，固定 position 升序）
│  ├─ chapter_ops.dart       # 章节操作：拆分/合并（Delta 纯函数）
│  ├─ writing_session.dart   # 写作会话追踪：本次字数/时长/速度
│  ├─ app_logger.dart        # 本地诊断日志：启动/升级/更新/异常 + 滚动保留
│  ├─ crash_journal.dart     # 未保存编辑缓冲的崩溃恢复日志
│  ├─ backup/                # 云备份 + 本地文件备份（见 docs/app/sync.md）
│  │  ├─ snapshot.dart       # 全量快照导出/恢复导入（v2：含分卷/状态/备注）
│  │  ├─ s3_store.dart       # R2 直连（SigV4 签名 PUT/GET）
│  │  └─ backup.dart         # 备份引擎：上传/下载状态机 + 本地导出/恢复
│  ├─ import_chenggua.dart   # 橙瓜码字 .db 导入器（图书/卷/章节 → 笔记本/分卷/章节，见 docs/app/import.md）
│  ├─ mcp/                   # 本地 MCP 服务（AI agent 读写书，仅回环 127.0.0.1）
│  │  ├─ mcp_tools.dart      # 6 个 MCP 工具声明（读/搜/建章/追章等，纯函数便于单测）
│  │  ├─ writing_skill.dart  # 写作 skill 文本（skills/zizai-writing 的生成源）
│  │  └─ mcp_server.dart     # mcp_dart Streamable HTTP server 包装
│  └─ update.dart            # 更新检查：清单、sha256 校验、安装
├─ state/
│  ├─ library_controller.dart  # 目录树 + 当前书/文档 + 未保存缓冲 + 今日增量
│  ├─ settings_controller.dart # 设置状态与持久化（含备份凭据、分卷/排序偏好）
│  └─ mcp_controller.dart      # 本地 MCP 服务启停（持久化 mcp.enabled/port）
├─ ui/
│  ├─ library_home.dart     # 笔记本管理层（书架 grid/list + 新建 + 全局设置）
│  ├─ shell.dart            # 单书工作区壳 + 自适应 + 全局快捷键
│  ├─ sidebar.dart          # 章节树（分卷分组、拖拽排序、状态标记、字数分布入口、本书设置）
│  ├─ editor.dart           # Quill 编辑器 + 常驻格式工具栏 + 选区浮动工具栏 + 自动保存 + IME 防护
│  ├─ status_bar.dart       # 字数/目标/备份状态/写作会话
│  ├─ focus_view.dart       # 沉浸模式包装
│  ├─ snapshot_panel.dart   # 版本历史对话框（列表 + 预览 + 回滚）
│  ├─ book_search_dialog.dart # 全书搜索与替换对话框（分组结果 + 跳转 + 替换预览）
│  ├─ find_bar.dart         # 单文档查找/替换条
│  ├─ outline_panel.dart    # 单文档大纲面板（可停靠/悬浮）
│  ├─ notes_panel.dart      # 章节备注面板（不进正文导出）
│  ├─ word_distribution_dialog.dart # 章节字数分布节奏图
│  ├─ book_settings.dart    # 本书设置对话框（目标/缩进/分卷/排序）
│  ├─ export_dialog.dart    # 整书导出选项对话框（含投稿格式复制）
│  ├─ slash_menu.dart       # 编辑器斜杠菜单
│  ├─ zz.dart               # 自绘 Notion 风控件（下拉菜单/switch/slider/dialog/toast）
│  ├─ glass.dart            # 实色表面组件（废弃毛玻璃后的扁平实现）
│  ├─ settings_view.dart    # 设置页/对话框（含备份区、AI 协作 MCP、关于区）
│  └─ preview/              # 静态 UI 预览（debug 用）
└─ util/
   ├─ debounce.dart          # 防抖
   ├─ ime_state.dart         # IME 组合状态追踪（防拼音误触）
   ├─ platform.dart          # 平台差异工具（含测试注入）
   ├─ chinese.dart           # 中文文本工具（标点/缩进）
   └─ date_format.dart       # 日期格式化
```

```text
（无独立后端：云备份直连 R2，见 docs/app/sync.md）
```

## 6. 所有权与状态流

```text
settings_controller ──读写──► settings 表
library_controller  ──读写──► db.dart（notebooks/documents/stats/last_open）
        │
        ├──► sidebar（读树，触发 CRUD/排序）
        ├──► editor（读写当前 Document Delta，触发自动保存）
        └──► status_bar（读今日增量/当前文档字数）
backup_manager ──(手动)──► db.dart 全量快照 + R2 直连   # 见 docs/app/sync.md
update_checker ──(异步)──► update.json（GitHub Releases）  # 见 docs/app/update.md
mcp_controller ──(可选)──► db.dart 读写（127.0.0.1 MCP，AI agent）  # 见 ui-settings.md「AI 协作」
```

- 状态所有者：`library_controller`（目录树、当前文档 id、未保存缓冲、今日增量）。
- 保存路径：编辑器变更 → 防抖 → `db.saveDocument()` → 返回字数增量 → 控制器更新今日增量。
- 设置路径：设置界面修改 → `settings_controller` → 写 settings 表 → 通知重建主题/字体。

## 7. 全局交互原则

- **自动保存优先**：任何时刻退出/切换都不弹「是否保存」。
- **无模态打断写作**：快捷键优先于菜单；删除是唯一需要确认的破坏性操作（轻量确认条）。
- **字数永不缺位**：状态栏常驻本文字数；当前笔记本启用目标时同时显示进度。
- **所见即所得**：编辑器渲染即效果，不提供任何预览层。
- **平台习惯**：桌面用 `Cmd/Ctrl` 快捷键 + 右键菜单；Android 用 Drawer + 长按菜单。

## 8. 平台差异

| 能力 | 桌面（Win/macOS） | Android |
|---|---|---|
| 布局 | 固定侧边栏 + 编辑器 | Drawer 抽屉 + 全屏编辑器 |
| 工具栏 | 常驻格式工具栏（H1–H3/粗斜体等始终可见）+ 选区浮动工具栏（选中文本浮现，Notion 式） | 同左，窄屏自适应 |
| 沉浸模式 | `Ctrl/Cmd+Shift+F` 进入；`Esc`/顶缘悬停条退出 | 系统返回手势/返回键退出；顶部 48px 热区兜底（点按弹「退出+字数」条、下滑直接退） |
| 删除确认 | 右键菜单 + 确认条 | 长按 + 确认条 |
| 导出 | 系统保存对话框选路径 | 系统分享（分享为文本） |
| 粘贴 | 桌面：Windows 按纯文本粘贴（flutter_quill 的富文本粘贴在 Windows 调 quill_native_bridge 读剪贴板 HTML 会崩溃，已关外部富文本粘贴）；macOS 保留富文本粘贴 | 系统剪贴板文本粘贴 |
| 窗口 | 可调大小，最小宽 800px | 竖屏优先 |

## 9. 关键设计决策（ADR）

| 决策 | 理由 | 代价 |
|---|---|---|
| SQLite 单库存储 | 富文本 Delta 需要结构化存储；单文件易备份 | 数据封闭在 db → 用导出功能兜底 |
| 所见即所得（flutter_quill） | 写作心智无「源码/预览」割裂；Quill 桌面移动均成熟 | 依赖第三方编辑器，样式需定制 |
| Android 存应用支持目录 | 免存储权限 | 手机端文件不外露，靠导出 |
| 单 ChangeNotifier + ListenableBuilder | 单用户单屏，复杂度低 | 多窗口/协同需重构 |
| 导出（纯文本 / Markdown 单文件 / Markdown 每章一文件）+ db 备份 | 数据安全出口；不依赖外部服务 | 导入方向仅橙瓜码字 + 未来 Markdown 导入 |
| 云备份以 R2 直连（S3 API + SigV4 自签） | 用户指定 CF 存储；免服务端部署、无 Worker；密钥仅存本地 settings 表 | 客户端实现签名；凭据泄露需手动轮换 |
| 全量快照上传/恢复 | 备份语义简单可预期；恢复前本地 .bak + R2 版本控制双兜底（永不丢字） | 无增量；恢复 = 全量替换 |
| 不选 D1 做云库 | SQLite 云库虽贴合本地，但免费档库容 500MB、同步逻辑更重；快照备份更简单 | 云侧无 SQL 查询能力 |
| DB schema 版本号（user_version）+ 前向迁移链 | 后续扩展字段安全演进（F8.2） | 迁移代码随版本积累，需回放测试 |
| 备份/更新 opt-in，默认离线 | 自用工具不绑架网络 | 多设备一致性依赖用户手动备份 |
