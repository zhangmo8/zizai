# Review shell-001-1 — 主界面壳

- 评审对象：commit `9b6999d`（`lib/app.dart`、`lib/main.dart`、`lib/state/{library,settings}_controller.dart`、`lib/ui/{shell,status_bar}.dart`、`lib/util/platform.dart`、`test/ui/shell_test.dart`；删除 `test/widget_test.dart`）
- 依据：docs/plan/tasks/shell-001.md；docs/app/ui-shell.md；docs/app/style.md（§3/§5/§9/§12）；docs/app/README.md（§4/§5/§6）；docs/app/update.md（§2）；docs/app/ui-sidebar.md / ui-editor.md（交叉引用）
- 评审方式：只读代码评审 + 在 9b6999d 的独立 worktree 上运行 `flutter analyze` + `flutter test`
- 日期：2026-08-06

## 结论：pass

Objective 4 项全部达成，与设计文档 contract 一致，无残留 stub/mock（编辑器内容区占位是 edit-003 排期分界，不算 stub）；analyze 无错误，42 个测试全部通过。非阻塞发现 5 条（见下），建议追加 backlog，不影响本任务验收。

## 验证命令结果

> 注：当前分支工作树混有 side-002 未提交 WIP（见「范围说明」），为对评审对象做干净验证，命令在 `git worktree add` 的 9b6999d 快照（`/tmp/zizai-shell001-review`）上执行。

| 命令 | 结果 |
|---|---|
| `flutter analyze` | `No issues found!` |
| `flutter test` | `+42: All tests passed!`（word_count 6 / export 6 / migration 4 / db 22 / shell 4） |

## 逐项证据

### Objective 1 — library_controller.dart ✅

- **目录树**：`notebooks`（`library_controller.dart:18`）；restore 中 `listNotebooks()` 装载。文档树全量 CRUD 归 side-002（任务 Path 亦未列），壳级目录树满足本任务。
- **当前文档**：`currentDocument`（`:22`）。
- **未保存缓冲 + 切换先保存**：`beforeSwitchSave` 注入点（`:33`），`switchDocument()` 先 `await beforeSwitchSave!()` 再加载新文档（`:56-64`）——即 ui-sidebar.md「单击文档 → 切换当前文档（先保存旧文档）」在壳层的落点；缓冲本体归 edit-003（Quill 文档），符合任务边界。
- **今日增量**：`todayDelta`（`:25`），restore 经 `_db.todayDelta()` 装载，`saveCurrentDocument` 保存后刷新（`:73`）。
- **restore 按 last_open 恢复**：`_db.loadLastOpen()` → `getDocument(lastOpen.documentId)`（`:43-46`）；无记录时 `currentDocument` 保持 null → 空态（ui-shell.md Interactions「启动 → 恢复上次文档；无记录则显示空态」）。✅
- **错误与重试**：`error` / `retry() => restore()` / `reportError` / `clearError`（`:88-99`）——ui-shell.md 存储错误条数据源齐备。

### Objective 2 — settings_controller.dart ✅

- **设置读写**：`load()` 从 settings 表载入（`:31-35`），`update()` 先通知（主题/字体即时生效）后持久化 `_db.saveSettings`（`:38-43`）。
- **主题三态**：`themeMode` 将 `theme`（'light'/'dark'/其他→system）映射为 `ThemeMode.light/dark/system`（`:21-25`），与 style.md §3「主题三态（跟随系统/浅色/深色）」一致。
- **变更通知**：`notifyListeners` 于 load/update 路径，`loaded` 标记存在（`:27`）。

### Objective 3 — shell.dart + status_bar.dart ✅

- **双形态**：断点 `>= 800` 桌面（`shell.dart:16,31`）；桌面 = Row（侧边栏 240px + 1px VerticalDivider + 编辑器区），侧边栏固定（`:37-46`）；<800 = `Scaffold(drawer: Drawer(width: 360))` + 编辑器全宽（`:48-51`）——Drawer 滑入 + 遮罩 0.3 黑为 Scaffold 内建，与 ui-shell.md Android 形态一致。
- **状态栏容器**（`status_bar.dart`）：高 32px + 顶部 hairline（`:25-27,60-63`，style.md §5/§9）；今日 `x/目标` + 进度条（`LinearProgressIndicator` minHeight 2、直角 ClipRRect、accent 色、百分比）+ `本文 x 字`（`:68-99`）；字数取 `currentDocument.words ?? 0`，空库/无文档时为 0（任务要求「本文字数先显示 0」✅，编辑逻辑归 edit-003）。
- **存储错误条**：`error != null` → 左侧 `colors.error` 图标+文案 + 「重试」按钮（`clearError + retry`，`:22-54`），符合 ui-shell.md State Variants「状态栏左侧红色错误条，点击重试」。
- **空库空态**：侧边栏空态 `_EmptyLibrary`（图标 + 斜体「还没有笔记本」+「新建笔记本」按钮，`:128-162`）；编辑器区空态「从这里开始写…」斜体（`:180-189`，ui-editor.md 空文档占位）；启动加载「载入中…」（`:178`）。「新建笔记本」按钮可实际创建（`createNotebook`，有 widget 测试覆盖）。

### Objective 4 — 主题接线 ✅

- `ZiZaiApp` 用 `ListenableBuilder(listenable: settings)` 包 `MaterialApp`，`themeMode: settings.themeMode`（`app.dart:113-121`）——三态实时生效。
- `AppTheme.light/dark` 用 `ColorScheme.fromSeed(seedColor: accent, brightness: ...)` + copyWith 覆盖纸墨层级：`surface←bg`、`onSurface←textPrimary`、`onSurfaceVariant←textSecondary`、`outline←hairline`，`scaffoldBackgroundColor: bg`、`dividerColor: hairline`（`app.dart:82-102`）。
- 色板值全部取自 style.md §3（浅 `#F7F6F3/#FCFBF9/#41695A…`，深 `#1B1B19/#21211F/#8FAD9E…`），代码内无硬编码散色（token 集中于 `AppTokens`，符合 §12「token 单源」）。

### Verification（widget test）✅

`test/ui/shell_test.dart` 4 条，与任务 Verification 逐项对应：
1. 桌面尺寸（1200×800）：侧边栏 + 空库引导 + 状态栏「今日 0/2000」「本文 0 字」，断言无 Drawer（`:36-53`）；
2. 手机尺寸（390×844）：Scaffold 挂 360px Drawer，右滑开 Drawer 见空库引导（`:55-72`）；
3. 空库点「新建笔记本」→ 侧边栏出现笔记本（`:74-86`）；
4. 有数据：今日增量 3/2000、本文 5 字、标题渲染（`:88-100`）。

另：`test/widget_test.dart`（脚手架 counter）已删除，env-001 评审建议闭环。

## 文档一致性（先改文档再改代码检查）

- **last-open.json vs last_open 表**：任务文本 shell-001.md 写「restore() 按 last-open.json 恢复」，而设计文档 README §4 为 SQLite `last_open` 表（store-001 已按其建表）。实现采用 `_db.loadLastOpen()` 表方案，与设计文档一致——**正确的文档优先选择**。
- **色值**：任务文本写「浅色 #FAF6EF / 深色 #1E1D1A / #3E6B5B」，style.md §3 为 `#F7F6F3 / #1B1B19 / #41695A`（深色 accent `#8FAD9E`）。实现采用 style.md 值（`app.dart:16-37`）——**正确的文档优先选择**。建议顺手修正 shell-001.md 任务文本中这两处过时描述，避免后续任务误读。
- **状态栏通栏与否**：ui-shell.md「Overall Structure」图示状态栏位于编辑器列下方（侧边栏不延伸），而「Region Layout（桌面）」图示状态栏通栏横贯侧边栏下方——两图自相矛盾。实现取 Overall Structure 读法（状态栏在编辑器列内，侧边栏右侧）。不构成违约，建议评审后回写文档统一为一种读法。

## 非阻塞发现（建议追加 backlog）

1. **token→ThemeData 映射不完整（style.md §3/§9）**：`copyWith` 把 `surface` 槽位覆盖成 `bg`（窗口底色），导致 style.md 的 `surface` token（浅 `#FCFBF9`，用途=侧边栏/对话框底）与 `surface-hover`、`text-tertiary`、`success` 均未接线；空态/占位文案用的 `onSurfaceVariant`（=text-secondary）而非规范要求的 text-tertiary。视觉可读性不受影响，但侧边栏与窗口同底色、略偏离「灰阶分层」；一行 copyWith 即可补齐，建议随 side-002 或打磨任务处理。
2. **侧边栏 Loading 态未按 State Variants 显示骨架条**：`library.loading` 时侧边栏因 notebooks 为空直接显示「还没有笔记本」引导而非骨架行×3；编辑器区「载入中…」正确。启动 loading 短暂、功能无碍；骨架条归 side-002 DocumentTree，建议该任务落地。
3. **`Ctrl/Cmd + B` 切换侧边栏显隐未实现**（ui-shell.md Interactions）：桌面形态侧边栏常驻，shell 无显隐状态。任务 Objective 未列此项，建议随 side-002 或专门跟进。
4. **同步状态点/指示未实现**（ui-shell.md Interactions + 状态栏 ●⟳⚠）：`status_bar.dart:1` 注释明确由 sync-ui-003 接入，属排期分界，仅记录。
5. **工作树混入 side-002 未提交 WIP（进程发现，非代码缺陷）**：`lib/state/library_controller.dart` 有未提交修改（文档树 CRUD + 删除确认条），`lib/ui/sidebar.dart` 未跟踪且当前缺 import 导致对整个工作树 `flutter analyze` 报 9 个错误（全部位于 sidebar.dart，与 9b6999d 无关）。建议 shell-001 merge 前与 side-002 开发串行化，避免验证噪声。

## 范围说明

- 本评审未修改任何代码/任务状态文件，仅新增本报告。验证在临时 worktree 快照上完成，用户工作树未动。
- 编辑器内容区占位（`_EditorArea` 显示标题文本）是 edit-003 排期分界，按任务提示不算 stub；`switchDocument` 内 last_open 写回（`db.saveLastOpen`）在 side-002 WIP 中补充，非本任务范围。

## 建议后续动作

- pass → merge 9b6999d 到 main → 全量测试 → shell-001 置 done。
- 非阻塞发现 1 优先级最高（token 映射补齐）；2/3 随 side-002；5 为流程项。
