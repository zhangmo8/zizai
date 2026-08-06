# 字在 — 产品与架构总览

Status: Draft（v2：SQLite 存储 + 所见即所得编辑器）

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
| 每日目标 | `dailyGoal` | 当日目标字数（可配置） |
| 今日增量 | `todayDelta` | 当日累计新增字数，见 §4 增量规则 |
| 沉浸模式 | `FocusMode` | 隐藏侧边栏、工具栏、状态栏的纯编辑状态 |
| 设备 | `Device` | 安装实例（UUID）；云同步的推送来源标记 |
| 同步状态 | `SyncState` | idle / syncing / error / off（状态栏指示） |
| DB schema 版本 | `schemaVersion` | `PRAGMA user_version`，迁移驱动（见 update.md） |

## 3. 信息架构

```text
字在
├─ 主界面（shell）
│  ├─ 侧边栏（笔记本 ▸ 章节树）
│  └─ 编辑器区（富文本所见即所得）
│     ├─ 上下文工具栏（选中文本时浮现）
│     └─ 状态栏（今日 x/目标 ▎本文 x 字）
├─ 沉浸模式（复用编辑器区，全屏无 chrome）
└─ 设置（对话框，桌面） / 设置页（Android）
```

桌面端入口：启动 → 打开上次文档 → 直接编辑。
Android 端入口：启动 → 文档树（有上次文档则直接打开，否则空态引导新建）。

## 4. 数据模型（SQLite v1）

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
  updated_at  INTEGER NOT NULL
);

CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE stats (
  date  TEXT PRIMARY KEY,   -- 'YYYY-MM-DD'
  words INTEGER NOT NULL
);

CREATE TABLE last_open (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  notebook_id TEXT,
  document_id TEXT,
  words       INTEGER NOT NULL DEFAULT 0  -- 该文档上次保存字数
);
```

- settings 键：`theme` / `fontFamily` / `fontSize` / `lineHeight` / `dailyGoal`。
- 升级路径：sqflite `onUpgrade` 版本化迁移（`PRAGMA user_version`）；**DB schema 版本号是长期演进基础**——任何加字段/改表必须走迁移链（见 docs/app/update.md §2）；升级前自动备份 db 文件为 `zi-zai.db.bak`（滚动保留 3 份）。
- 云同步数据模型与 blob 结构见 docs/app/sync.md。
- db 位置：`path_provider` 应用支持目录，桌面与 Android 一致；设置页展示路径。

### 增量规则

每次保存：`增量 = 本次纯文本字数 − 上次保存字数快照`；增量 > 0 累加当日 `stats`，增量 < 0 扣减当日但不下探到 0 以下；字数快照写回 `documents.words` 与 `last_open.words`。

## 5. 模块划分

```text
lib/
├─ main.dart                 # 入口：App 装配、主题
├─ app.dart                  # MaterialApp、路由、主题选择
├─ core/
│  ├─ models.dart            # Notebook / Document / Settings 数据类
│  ├─ db.dart                # SQLite 打开、schema、CRUD、迁移链（user_version）
│  ├─ word_count.dart        # 字数算法（纯函数，输入纯文本）
│  ├─ export.dart            # 文档 → 纯文本导出
│  ├─ sync/                  # 云同步（见 docs/app/sync.md）
│  │  ├─ protocol.dart       # envelope / pull / push / 版本协商
│  │  └─ client.dart         # 同步引擎：journal、LWW 应用、退避重试
│  └─ update.dart            # 更新检查：清单、sha256 校验、安装
├─ state/
│  ├─ library_controller.dart  # 目录树 + 当前文档 + 未保存缓冲 + 今日增量
│  └─ settings_controller.dart # 设置状态与持久化（含同步配置）
├─ ui/
│  ├─ shell.dart             # 主界面壳 + 自适应
│  ├─ sidebar.dart           # 文档树
│  ├─ editor.dart            # Quill 编辑器 + 上下文工具栏 + 自动保存
│  ├─ status_bar.dart        # 字数/目标/同步状态
│  ├─ focus_view.dart        # 沉浸模式包装
│  └─ settings_view.dart     # 设置页/对话框（含同步区、关于区）
└─ util/
   ├─ debounce.dart          # 防抖
   └─ platform.dart          # 平台差异工具
```

```text
worker/                      # CF Worker 网关（云同步，独立部署）
├─ src/index.ts              # pull/push、token 校验、服务器时间戳
├─ wrangler.toml             # R2 bucket 绑定、secret 声明
└─ README.md                 # 部署步骤（wrangler deploy、开启 bucket 版本控制）
```

## 6. 所有权与状态流

```text
settings_controller ──读写──► settings 表
library_controller  ──读写──► db.dart（notebooks/documents/stats/last_open）
        │
        ├──► sidebar（读树，触发 CRUD/排序）
        ├──► editor（读写当前 Document Delta，触发自动保存）
        └──► status_bar（读今日增量/当前文档字数）
sync_client ──(异步)──► db.dart + R2(经 Worker)   # 见 docs/app/sync.md
update_checker ──(异步)──► R2 update.json          # 见 docs/app/update.md
```

- 状态所有者：`library_controller`（目录树、当前文档 id、未保存缓冲、今日增量）。
- 保存路径：编辑器变更 → 防抖 → `db.saveDocument()` → 返回字数增量 → 控制器更新今日增量。
- 设置路径：设置界面修改 → `settings_controller` → 写 settings 表 → 通知重建主题/字体。

## 7. 全局交互原则

- **自动保存优先**：任何时刻退出/切换都不弹「是否保存」。
- **无模态打断写作**：快捷键优先于菜单；删除是唯一需要确认的破坏性操作（轻量确认条）。
- **字数永不缺位**：状态栏常驻今日目标进度与本文字数。
- **所见即所得**：编辑器渲染即效果，不提供任何预览层。
- **平台习惯**：桌面用 `Cmd/Ctrl` 快捷键 + 右键菜单；Android 用 Drawer + 长按菜单。

## 8. 平台差异

| 能力 | 桌面（Win/macOS） | Android |
|---|---|---|
| 布局 | 固定侧边栏 + 编辑器 | Drawer 抽屉 + 全屏编辑器 |
| 工具栏 | 选中文本浮现（上下文工具栏，Notion 式） | 选中文本时顶部弹出 |
| 沉浸模式 | `Ctrl/Cmd+Shift+F` 进入；`Esc`/顶缘悬停条退出 | 系统返回手势/返回键退出；顶部 48px 热区兜底（点按弹「退出+字数」条、下滑直接退） |
| 删除确认 | 右键菜单 + 确认条 | 长按 + 确认条 |
| 导出 | 系统保存对话框选路径 | 系统分享（分享为文本） |
| 窗口 | 可调大小，最小宽 800px | 竖屏优先 |

## 9. 关键设计决策（ADR）

| 决策 | 理由 | 代价 |
|---|---|---|
| SQLite 单库存储 | 富文本 Delta 需要结构化存储；单文件易备份 | 数据封闭在 db → 用导出功能兜底 |
| 所见即所得（flutter_quill） | 写作心智无「源码/预览」割裂；Quill 桌面移动均成熟 | 依赖第三方编辑器，样式需定制 |
| Android 存应用支持目录 | 免存储权限 | 手机端文件不外露，靠导出 |
| 单 ChangeNotifier + provider | 单用户单屏，复杂度低 | 后续多窗口/协同需重构 |
| V1 纯文本导出 + db 备份 | 数据安全出口最小实现 | 导出 md 全集要等 V2 |
| 云同步以 R2 为基准 + Worker 网关 | 用户指定 CF 存储；R2 免 egress、免费额度足；Worker 免客户端嵌 S3 密钥、服务器签发时间 | 多一个 Worker 部署步骤 |
| 文档级 LWW + 输家双备份 | 单用户跨设备足够；绝不静默丢字（本地 .sync-bak + R2 版本控制） | 同文档双端同改，一端需手工找回（有备份） |
| 不选 D1 做云库 | SQLite 云库虽贴合本地，但免费档库容 500MB、同步逻辑更重；blob 同步更简单 | 云侧无 SQL 查询能力 |
| DB schema 版本号（user_version）+ 前向迁移链 | 后续扩展字段安全演进（F8.2） | 迁移代码随版本积累，需回放测试 |
| 同步/更新 opt-in，默认离线 | 自用工具不绑架网络 | 多设备一致性依赖用户开启 |
