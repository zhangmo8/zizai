# Review sync-ui-003-1 — 同步设置与状态指示

- 评审对象：commit `7e79f3a` 的 sync-ui-003 部分（`lib/ui/settings_view.dart` 同步区、`lib/ui/status_bar.dart` `_SyncIndicator`、`lib/core/sync/client.dart` ChangeNotifier/conflictBackups/setBaseUrl/effectiveBaseUrl、`lib/ui/editor.dart`/`shell.dart`/`app.dart`/`main.dart` 接线、`test/ui/sync_test.dart` 5 用例）。该提交同时含 sync-engine-002 阻塞修复（`db.dart` saveDocument onMutation），不在本任务评审范围（已由 sync-engine-002-1 复评 pass）。
- 依据：docs/plan/tasks/sync-ui-003.md（Objective 3 项 + Verification）；docs/app/ui-settings.md（§同步区、Interactions、State Variants）；docs/app/ui-shell.md（§Interactions 同步状态点、同步状态显示规则）；docs/app/style.md（§3 tokens、§9 状态色）；docs/app/sync.md（§5 输家保护、§6 状态机、§7 安全）
- 评审方式：只读代码评审。主工作树 clean（tracked 恰为 7e79f3a；未跟踪仅 `docs/plan/reviews/sync-engine-002-1.md` 与本报告、`output/`），结果可完全归因于 7e79f3a；未修改任何代码文件，仅新增本报告
- 日期：2026-08-06

## 结论：blocked

Objective 1 的控件齐备与 token 安全、Objective 3 冲突提示、状态栏三态文案与色槽、`flutter analyze` 无错误、`flutter test` 83/83 全部通过——这些均达成。

但存在 **2 项 blocking**：

1. **B1：同步地址（`effectiveBaseUrl`）定义后从未使用** —— `_post` 实际用构造参数 `baseUrl`（[client.dart](lib/core/sync/client.dart#L454)），而 `main.dart` 以 `baseUrl: ''` 创建引擎（main.dart:46）。设置页「同步地址」写入的 `sync.baseUrl`（`setBaseUrl` → `_baseUrlOverride`，client.dart:110-116）永不生效；`effectiveBaseUrl` 全 lib 仅定义、零引用。生产环境下唯一可配置地址的入口是死代码，请求落到相对 URI `/sync/push`（无 host）→ 恒失败。同步地址输入实际为 stub → blocking（「残留 stub/mock」）。
2. **B2：`setEnabled(false)` 不通知 UI** —— 关闭开关路径为 `_enabled=false` + `db.setSetting(syncDirty:false)`，无 `notifyListeners`、无 `onMutation`（db.dart:438-445 对 `sync.*` 键 syncDirty:false 不标脏不回调）。设置页 Switch（`ListenableBuilder(listenable: sync)`）与状态栏 `_SyncIndicator` 均不重建：开关视觉停留在「开」、状态栏指示不消失——与 Objective 2「云同步关闭时不显示」contract 直接违背 → blocking。

## 验证命令结果（7e79f3a，主工作树）

| 命令 | 结果 |
|---|---|
| `flutter analyze` | `No issues found!` |
| `flutter test` | `All tests passed!`（+83，共 83 用例，含 ui/sync_test.dart 5 用例） |

## 逐项证据

### Objective 1 — 设置页同步区 ✅（除 B1/B2 关联项）

- **云同步开关默认关闭 + 持久化**：`_enabled` 初始 false，`_readConfig` 读 `sync.enabled=='1'`（client.dart:91-95）；开启写 `sync.enabled`（client.dart:97-103）。测试「开关切换 → 持久化」断言 db 值 `'1'` 与 `lastSyncAt` 刷新。✅（**关闭路径见 B2**）
- **令牌掩码 + 仅存本地 settings 表**：`obscureText: true`（settings_view.dart:370）；`setToken` 写 `sync.token` 且 `syncDirty: false`（client.dart:105-108）；push 的 settings envelope 剔除 `sync.*` 键（client.dart:172-177）、pull 应用跳过 `sync.*`（client.dart:399）；envelope 结构体无 token 字段，token 仅进 `Authorization` 头（client.dart:451-461）。测试「令牌输入掩码 + 仅存本地」断言 db 值 + `obscureText`；sync-engine-002 已有「token 不进 envelope」显式断言。✅
- **上次同步时间**：`lastSyncAt` + 相对时间（「刚刚 / n 分钟前 / …」+ 本地绝对时间），null 显示「从未同步」（settings_view.dart:381-402）。✅（跨重启持久化见非阻塞 2）
- **立即同步 loading + 失败错误 + 重试**：syncing 时按钮禁用并转圈，`lastError` 显示 error 色文案 + 「重试」按钮（settings_view.dart:404-450）。✅
- **同步地址**：输入项存在（settings_view.dart:354-365）——「已知偏差」确认为合理补全（token 自配 Worker 必须可配置地址）。**但实现无效，见 B1**。

### Objective 2 — 状态栏同步指示 ⚠️（B2 关联）

- 文案与色值：`● 已同步`（`colors.primary` = accent 精确映射，app.dart:88 `copyWith(primary: accent)`）/ `⟳ 同步中`（`colors.onSurfaceVariant` = text-secondary，app.dart:91）/ `⚠ 失败 n 次`（`colors.error`，**非 danger token，见非阻塞 3**）（status_bar.dart:196-208）。文案逐字符合 ui-shell.md。✅
- 点击入口：`InkWell onTap → onOpenSettings(focusSync: true)` → 桌面对话框 / Android 全屏页打开设置（status_bar.dart:203、editor.dart:304-307,375-382）。✅（定位行为见非阻塞 1）
- 关闭时不显示：`if (!sync.enabled) return SizedBox.shrink()`（status_bar.dart:193）——逻辑在，但依赖 notify 触发重建，**关闭路径无 notify（B2），实际不消失**。
- 关闭（syncClient == null）时不显示：`if (widget.syncClient != null)` 整体隐藏（status_bar.dart:160-163），单测路径安全。✅

### Objective 3 — 冲突提示 ✅

- 输家备份计数 `conflictBackups` 在 `_backupLocal` 时 +1（client.dart:433）；设置页显示「有 n 份本地版本已备份于 {backupDir}/sync-bak，可在云端版本控制找回」（settings_view.dart:171-182），含备份目录路径。✅（状态栏或设置页二选一即满足任务；计数为会话级见非阻塞 5）

### 引擎侧（复用 sync-engine-002 保证）✅

- ChangeNotifier 化：`_setSyncing/_setIdle/_onSuccess/_onFailure/_backupLocal` 均补 `notifyListeners`（client.dart:433-434,477-509），状态机 idle/syncing/error + failureCount 语义未变。✅
- `dispose` 补 `super.dispose()`（client.dart:130-137）。✅

## 非阻塞发现（建议追加 backlog）

1. **`autoFocusSync` 死参数**：SettingsView 声明并接收（settings_view.dart:62），但 `initState`/build 仅处理 `autoFocusDailyGoal`（settings_view.dart:80-83），无滚动/定位逻辑。状态栏同步指示点击「进入设置页同步区」只打开对话框（同步区本就随 syncClient 非空常显，落差小）——建议补 Scrollable.ensureVisible 或移除参数。
2. **「上次同步」不跨重启**：`lastSyncAt` 为会话内 ValueNotifier，重启后恒显「从未同步」；`sync.lastPulledAt` 已持久化（client.dart:300-301）却未用于回显。sync.md §4「客户端只报告上次拉取时间」——建议 initialize 时回填。
3. **danger token 未接线**：`AppTokens.lightDanger/darkDanger` 传入 `AppTheme._build` 后未使用（app.dart:54,68,82——`danger`/`success` 参数均为死参），`⚠ 失败 n 次` 与错误文字落到 M3 默认 error（高饱和红），非 style.md §3 低饱和砖红 `#B0564C`。与 backlog 15/16（主题 token 映射不完整）同类，建议统一处理。
4. **同步区控件关闭时全显**：ui-settings.md 写「开启后显示令牌输入与状态」，实现为开关/地址/令牌/上次同步/立即同步恒显（settings_view.dart:164-184）。信息不敏感、行为安全，与设计措辞有出入。
5. **conflictBackups 为会话级计数**：重启归零，`.sync-bak` 目录仍存在时提示消失（sync.md §5.3「状态栏出现备份提示」未指定跨重启语义）；另该计数不区分新旧（提示永不消失直到重启）。
6. **重试期间旧错误滞留**：`_setSyncing` 不清 `lastError`，同步中按钮转圈与旧错误文案同显（视觉噪音，功能无损）。
7. **同步地址字段初始值**：controller 取构造参数 `baseUrl`（settings_view.dart:337-338）而非已存 `sync.baseUrl`，重启后字段显示空——与 B1 同源，修复 B1 时一并处理（controller 用 `effectiveBaseUrl`）。
8. **测试缺口**（与 B1/B2 同源）：开关关闭后 UI 刷新（Switch 视觉、状态栏消失）无用例；「同步地址」字段保存后真实请求生效路径无用例（现有测试均构造注入 baseUrl）。

## 范围说明

- 主工作树 tracked 恰为 7e79f3a，未跟踪仅 `docs/plan/reviews/sync-engine-002-1.md`（前一任务产物）与 `output/`（构建产物），无其它任务改动，无需 detached worktree。
- `db.dart` saveDocument onMutation（sync-engine-002 阻塞修复）不在本任务范围，未评审；其复评结论为 pass。
- 未修改任何代码/任务状态文件，仅新增本报告；未触碰 backlog.md，非阻塞发现由计划循环侧追加。

## 建议后续动作（blocked → 修复 → 同分支 re-verify）

- **B1 修复**：`_post` 改用 `effectiveBaseUrl`（client.dart:454 `Uri.parse('${effectiveBaseUrl}$path')`）；补一条「setBaseUrl → syncNow 请求打到新地址」的单测（fake server 可断言 host/path）；顺带处理非阻塞 7（字段初始值）。
- **B2 修复**：`setEnabled` 末尾（含关闭分支）补 `notifyListeners()`；补用例「关闭开关 → Switch 值 false + 状态栏同步指示消失」。
- 其余 Objective 与 83 用例已绿，修复后重跑 `flutter analyze` + `flutter test` 即可 re-verify 放行。
