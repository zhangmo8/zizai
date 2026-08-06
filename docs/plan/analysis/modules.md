# 模块分解与任务拆分

Status: Draft（v2：SQLite + Quill）
依据：docs/app/README.md §5、docs/plan/analysis/requirements.md

## 1. 模块职责

| 模块 | 输入 | 输出/职责 | 依赖 |
|---|---|---|---|
| `core/models` | — | `Notebook` / `Document` / `Settings` 数据类、Delta JSON 载体 | 无 |
| `core/db` | db 路径 | schema 创建/迁移、笔记本与文档 CRUD、settings/stats/last_open 读写、保存增量计算 | `core/models`, `core/word_count` |
| `core/word_count` | 纯文本 | `int` 字数（纯函数） | 无 |
| `core/export` | Document | 纯文本导出（toPlainText + 文件名整理） | `core/models` |
| `state/library_controller` | `core/db` | 目录树、当前文档、未保存缓冲、今日增量；通知 UI | `core/db` |
| `state/settings_controller` | `core/db` | 设置状态 + 持久化（含同步配置）+ 主题/字体通知 | `core/db` |
| `core/sync/protocol` | — | envelope 序列化、pull/push 请求、版本协商（X-Sync-Protocol） | 无 |
| `core/sync/client` | `core/db` + protocol | 同步引擎：journal、脏标记、LWW 应用、tombstone、`.sync-bak`、退避重试 | `core/db`, protocol |
| `core/update` | `core/db` | 更新清单拉取/比较、sha256 校验、下载安装 | `core/db` |
| `worker/` | — | CF Worker 网关：pull/push、token 校验、服务器时间戳、R2 读写（独立部署，TypeScript） | 无 |
| `ui/shell` | 两个 controller | 壳布局、自适应、状态栏容器 | 全部 UI |
| `ui/sidebar` | library_controller | 文档树、CRUD、上移/下移 | library_controller |
| `ui/editor` | library_controller | Quill 编辑器 + 上下文工具栏 + 防抖自动保存 + 字数 | library_controller, `core/word_count` |
| `ui/status_bar` | library_controller + sync client | 今日进度 + 本文字数 + 同步状态 | library_controller |
| `ui/focus_view` | editor | 沉浸模式包装、快捷键 | editor |
| `ui/settings_view` | settings_controller + library_controller | 设置编辑、导出、同步配置、关于/更新 | 两者 + `core/export` + sync client + `core/update` |
| `util/debounce`, `util/platform` | — | 防抖；平台判断 | 无 |

## 2. 第三方依赖（env-001 引入）

| 包 | 用途 | 说明 |
|---|---|---|
| `sqflite` + `sqflite_common_ffi` | 数据库 | 移动端 + 桌面端同一 API |
| `path_provider` | db 路径 | 应用支持目录 |
| `flutter_quill` | 所见即所得编辑器 | Delta JSON 存储 |
| `file_selector`（桌面）/ `share_plus`（Android） | 导出 | 保存对话框 / 系统分享 |
| `http` | 同步/更新 | Worker REST + update.json |
| `crypto` | sha256 | 安装包校验 |

## 3. 集成枚举（创建/调用/注入链）

1. `main.dart` → 打开 db → 创建 `SettingsController` + `LibraryController`（注入同一 `Db`）→ 注入 `Shell`。
2. `Shell` → 构建 `Sidebar` / `EditorView` / `StatusBar`（各自消费 controller）。
3. `Sidebar` 选择文档 → `LibraryController.switchDocument()` → 保存旧文档 + 加载新文档 → `EditorView` 重载。
4. `EditorView` 输入（Delta 变更）→ debounce → `Db.saveDocument()` → 字数增量 → controller 更新 `todayDelta` → `StatusBar` 刷新。
5. `SettingsView` 修改 → `SettingsController` → 写 settings 表 → 主题/字号/行距重建 UI。
6. 启动恢复链：`main.dart` → `Db.loadLastOpen()` → `LibraryController.restore()` → 打开上次文档。
7. 导出链：`SettingsView` → `core/export` → 桌面文件保存 / Android 系统分享。
8. 同步链：保存事件/定时器 → `sync/client` push（读本地脏行）→ Worker → R2；`sync/client` pull（`since`）→ Worker → 本地 LWW 应用（含 tombstone 与 `.sync-bak`）。
9. 更新链：启动/设置页 → `core/update` → R2 update.json → 版本比较 → sha256 校验 → 安装。

必须用真实实现打通（非 mock）：3、4、6、7、8（双设备模拟）、9（清单/校验）。

## 4. 任务拆分

| 任务 | 内容 | 依赖 | 验证出口 |
|---|---|---|---|
| [env-001](tasks/env-001.md) | Flutter SDK + 脚手架 + 依赖 + git init | — | 三平台目录存在，`flutter test` 通过 |
| [store-001](tasks/store-001.md) | `core/*`（db 含迁移链/word_count/export/models）+ 单测 | env-001 | 单测覆盖 CRUD/增量/字数/迁移回放 |
| [shell-001](tasks/shell-001.md) | 壳 + 状态栏（含同步指示） + 主题接线 + 自适应 | store-001 | widget test：壳渲染、空态、双形态 |
| [side-002](tasks/side-002.md) | 文档树 + CRUD + 排序 | shell-001 | widget test：CRUD 与上移/下移 |
| [edit-003](tasks/edit-003.md) | Quill 编辑器 + 上下文工具栏 + 自动保存 + 沉浸 | side-002 | widget test：输入→保存→字数；FocusMode |
| [set-004](tasks/set-004.md) | 设置页 + 导出 + 关于区 | shell-001 | widget test：设置持久化、导出、版本展示 |
| [sync-worker-001](tasks/sync-worker-001.md) | CF Worker 网关 + R2（含部署文档） | env-001 | Worker 单测 + 本地模拟 R2 测试 |
| [sync-engine-002](tasks/sync-engine-002.md) | Dart 同步引擎（journal/LWW/tombstone/退避） | store-001, sync-worker-001 | 单测：双设备模拟、冲突、tombstone |
| [sync-ui-003](tasks/sync-ui-003.md) | 设置页同步区 + 状态栏指示 | set-004, sync-engine-002 | widget test：开关/令牌/立即同步/指示 |
| [upd-001](tasks/upd-001.md) | 更新检查（清单/sha256/安装）+ DB 迁移链落地 | store-001 | 单测：版本比较、sha256 拒绝、迁移回放 |
| [integ-005](tasks/integ-005.md) | 端到端：写→存→重启→恢复；双设备同步；三平台冒烟 | edit-003, set-004, sync-ui-003, upd-001 | 冒烟清单 + 集成测试 |
| [pkg-006](tasks/pkg-006.md) | 三端构建 + 上传 R2（更新清单） | integ-005 | 构建产物 + update.json 发布 |

## 5. 串行约束

无 worktree，任务串行：
store-001 → shell-001 → (side-002 → edit-003, set-004) → sync-worker-001 → sync-engine-002 → sync-ui-003 → upd-001 → integ-005 → pkg-006。
