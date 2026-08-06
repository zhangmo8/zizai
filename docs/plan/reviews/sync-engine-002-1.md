# Review sync-engine-002-1 — Dart 同步引擎（journal / push-pull / LWW / 退避）

- 评审对象：commit `ca673cc`（`lib/core/sync/protocol.dart`、`lib/core/sync/client.dart`、`lib/core/db.dart` schema v2（`sync_journal` + `notebooks.updated_at` + 脏标记 + 云应用方法 + `onMutation`）、`lib/core/models.dart`（Notebook.updatedAt）、`test/core/sync/fake_server.dart` + `sync_client_test.dart` 8 用例、`test/core/migration_test.dart` 更新、若干既有测试适配）
- 依据：docs/plan/tasks/sync-engine-002.md（Objective 3 项 + Verification）；docs/app/sync.md §3–§7（envelope、协议 v1、LWW、输家保护、状态机、安全）；docs/app/update.md §1–§2（版本协商、迁移链纪律）
- 前置：sync-worker-001 pass（`worker/src/index.ts` wire contract 已核对，fake server 与之一致）
- 评审方式：只读代码评审 + 干净工作树命令链验证（见「范围说明」）；未修改任何代码文件，仅新增本报告
- 日期：2026-08-06

## 结论：blocked

Objective 1（protocol）、Objective 3（双设备冲突语义）、schema v2 迁移链纪律、`flutter analyze` 无错误、`flutter test` 77/77 全部通过——这些均达成。

但 **Objective 2「触发：保存防抖 30s 推送」对文档保存路径不生效**（设计 contract sync.md §6「保存防抖 30s ─► push」未达成）：`saveDocument` 走事务内 `_markDirtyOn`（[db.dart](lib/core/db.dart#L403)），该方法**不调用 `onMutation`**（db.dart:174-181），而 `schedulePush` 的唯一调用点就是 `onMutation` handler（[client.dart](lib/core/sync/client.dart#L79)）。即：用户自动保存文档 → journal 标脏成功 → 但永远不调度 30s 防抖推送；且启动只 `pull` 不 `push`，脏文档会无限期滞留本地（除非手动「立即同步」/开关同步/此前已有失败在退避）。编辑器自动保存是本应用最高频变更，属核心同步主链路，与任务 Objective 明确项不一致 → blocking。

## 验证命令结果（干净工作树 ca673cc）

| 命令 | 结果 |
|---|---|
| `flutter analyze` | `No issues found!` |
| `flutter test` | `All tests passed!`（+77，共 77 用例） |
| `flutter pub get` | 成功（与 ca673cc 的 pubspec.lock 一致） |

## 逐项证据

### Objective 1 — `protocol.dart`：envelope / 请求构造 / 409 协商 ✅

- **envelope 序列化**：`SyncEnvelope.toJson/fromJson`（protocol.dart:28-46）字段与 sync.md §3 示例逐字一致：`t/id/data/deleted/updatedAt/device/schemaVersion`；`t` 取值 doc/notebook/settings/stats（注释 protocol.dart:19）。✅
- **push/pull 请求构造**：push 体 `{deviceId, schemaVersion, blobs:[envelope]}`（client.dart:136-140）、pull 体 `{deviceId, since}`（client.dart:262-265）与 sync.md §4 接口表一致；请求头 `X-Sync-Protocol: 1` + `Authorization: Bearer <token>`（client.dart:433-445）。✅
- **409 → 可读错误**：非 200 时 409 单独判 `SyncProtocolException(status, code, message)`，message 固定「同步协议/数据版本过旧，请升级 App」（client.dart:446-453）；与 worker 端 `protocol_mismatch`/`schema_mismatch` 409 响应（worker/src/index.ts:92-94,100-102）对应。测试「409 协议不匹配 → 可读错误 + error 状态 + 退避调度」✅
- 版本常量 `syncProtocolVersion = 1`、`syncSchemaVersion = 1` 与 worker `PROTOCOL_VERSION/SCHEMA_VERSION = 1` 一致。✅

### Objective 2 — `client.dart` ✅（除下述 blocking 项）

- **journal 脏标记**：v2 迁移建 `sync_journal(entity_id PK, dirty, last_pushed_at, last_pulled_at)`（db.dart:36-42）；脏标记覆盖 create/save/rename/delete/move(notebook)/settings/stats（db.dart:240,263,272-274,289-291,319,356,362,403,406,434,452）。推送成功 `clearDirty`（client.dart:142-144, db.dart:560-567）；拉取 `touchPulled`（db.dart:570-576）。✅
- **push**：脏实体 → envelope——文档含 Delta/标题/字数（client.dart:231-252）、笔记本含 name/position（client.dart:194-204）、settings 整对象、stats `{dates}`；**`sync.*` 键剔除**（client.dart:158-163，测试「settings 推送：token 等 sync.* 键绝不进入 envelope」显式断言）。✅
- **pull LWW**：云端 `updatedAt > 本地` → `applyCloudDocument` 替换（client.dart:328-344）；否则仅 `touchPulled`；tombstone → 本地脏时先备份再 `removeEntityNoDirty`（client.dart:317-327）。✅
- **输家保护**：`.sync-bak/{docId}-{ts}.json`，按 doc.id 过滤保留最近 5 份（client.dart:404-429）；`conflictBackups` 计数供状态栏提示（同步字段）。测试「冲突：双端同改 → LWW 云端胜 + 输家 .sync-bak 备份」✅
- **settings 整对象 LWW**：pull 应用时逐键写入、`sync.*` 跳过（client.dart:380-388）——见非阻塞 1（union 而非严格整对象替换，保守不丢键）。
- **stats 按 date 键合并**：`upsertStat` 逐 date 取 max（db.dart:595-606，注释「保守不丢字」）——见非阻塞 2。
- **触发**：
  - 启动拉取 ✅：`initialize` → `if (_enabled) unawaited(pull())`（client.dart:82-84）。
  - 保存防抖 30s ❌：**见 blocking 结论**。`schedulePush` 唯一调用点为 `db.onMutation` handler（client.dart:79），而文档保存路径 `saveDocument` 仅用事务内 `_markDirtyOn`（db.dart:403,406），不触发 `onMutation`（db.dart:174-181 无回调）。`_markDirty`（非事务）才会 `onMutation?.call()`（db.dart:170）。grep 全 lib/ 确认无其它 schedulePush 调用点，UI 层也无「保存后手动调度」逻辑（sync-ui-003 未合入；ca673cc 上 SyncClient 仅测试与 settings_view 可选参数引用）。
  - 立即同步 ✅：`syncNow()` = push + pull（client.dart:112-115），设置页手动按钮即调它。
  - 指数退避 30s/1m/5m/上限 1h ✅：`retryDelayFor`（client.dart:24-33）+ `_onFailure` 定时 `syncNow`（client.dart:478-488）；测试逐档断言。
- **状态机**：`SyncState {idle, syncing, error}` + `failureCount`（client.dart:21,53-56）；成功清零、失败累加；`_applying` 标志抑制 pull 应用期间的回环触发（client.dart:267-284,81）。✅
- **token 安全**：token 仅存 `Authorization` 头（client.dart:440）；push 体（deviceId/schemaVersion/blobs）与 settings envelope 均无 token（`sync.*` 剔除）；`sync.token/enabled/deviceId/lastPulledAt/baseUrl` 均以 `syncDirty: false` 写库（client.dart:76,94,102,286,434）。✅

### Objective 3 — 双设备冲突语义与备份（sync.md §5）✅

测试 8 用例覆盖：双设备 A push → B pull 一致、同文档冲突 LWW + `.sync-bak` 生成、tombstone 跨设备传播（且云端保留 deleted:true）、增量 pull 游标、推送后清脏、settings token 剔除、409 可读错误、退避序列。fake server 为「协议兼容的测试服务器」（单测层 mock 属允许范围，与真实 Worker 同 wire contract，端到端归 integ-005）。✅

### db 改动与迁移链纪律（update.md §2）✅

- v2 迁移脚本在 `schemaMigrations` 有序链内（db.dart:30-47）；打开库 onCreate 建 v1 后走同一迁移链（db.dart:118-121）、onUpgrade 先 `backupDbFile`（滚动 3 份）再逐级迁移（db.dart:123-126）；迁移失败抛 `LibraryException`（停止启动，db.dart:132-137）——与 update.md「升级前备份 / 失败停止启动 / 只前向」一致。✅
- **回放测试**：migration_test.dart「迁移链回放：v1 逐级升到 v3（真实 v2 + 扩展 v3）」，从 v1 空库写入数据 → 用 `schemaMigrations`（真实 v2）+ 合成 v3 逐级升级 → 断言表结构（6 表 + `notebooks.updated_at`）、数据无损、`.bak` 存在；另有 fresh 库 6 表断言、迁移失败注入（抛错 + 备份可恢复 + 重试成功）、备份滚动 3 份测试。✅
- **v1 库容忍**：`_syncJournalExists`/`_nbHasUpdatedAt` 打开时探测（db.dart:149-161），v1 库（无 journal 表）写路径自动跳过脏标记，迁移测试场景即此。✅
- **onMutation**：`SyncClient.initialize` 挂接（client.dart:78-80）、`dispose` 解除（client.dart:120-122）、pull 应用期间抑制（`_applying`）——机制正确，唯一缺陷是事务路径不触发（blocking 项）。

## 非阻塞发现（建议追加 backlog）

1. **settings「整对象 LWW」实现为逐键 union 合并**：`_applySettings` 只写云端带出的键、不删本地独有键（client.dart:380-388），与「整对象 LWW」严格语义（整对象替换）有出入。当前 settings 无删除 API，实际影响小且保守不丢配置；建议文档或实现二选一对齐。
2. **stats「按 date 键逐条 LWW」实现为取 max**（db.dart:595-606）：envelope 无 per-date 时间戳（`{dates:{...}}` 整对象），max 是保守近似（累计字数不回退）；与文档措辞差异建议注明。
3. **moveDocument 不标脏**：Objective 措辞「脏标记覆盖 … move …」，但文档 envelope（sync.md §3）不含 position，文档排序本就不同步（notebook position 不同步于 envelope 中，moveNotebook 已标脏）；建议任务文档注明「文档 position 不在同步数据模型内」以消除歧义。
4. **备份文件名 `{docId}-{ts}.json` 与 sync.md §5 写法的 `{docId}.json` 字面不一致**（实现更合理，可保多份）；`f.path.contains(doc.id)` 在 docId 前缀重叠时可能误删他人备份（随机 UUID 实际不可达）。
5. **测试缺口**：`onMutation`/30s 防抖触发路径无单测（与 blocking 项同源，修复后应补「save → 定时器到期 → push」用例）；settings/stats 的 pull 应用（跨设备）无单测（push 侧有）；增量 pull 用例中 `server.store.length` 断言不验证「无多余请求」（fake server 无请求计数，游标语义由 since 保证——可接受或给 fake server 加计数）。
6. **db.dart 顶部注释「schema v1 + 迁移链框架」已过时**（`currentSchemaVersion = 2`，db.dart:1,18），建议改「schema v2」。
7. **sync_client_test.dart 末尾残留 `const ziZaiSettings = Settings;` 死代码**（analyze 不报，top-level public 无 unused 警告），建议删除。

## 范围说明

- 评审时主工作树存在**未提交的后续任务 WIP**（`lib/core/sync/client.dart`、`lib/ui/editor.dart`、`lib/ui/settings_view.dart`、`lib/ui/status_bar.dart` 被改动——疑似 sync-ui-003：ChangeNotifier/conflictBackups/baseUrl 覆盖/状态栏同步区），与本次评审对象无关且未合入。为确保结果可归因于 ca673cc，全部代码阅读与 `flutter analyze`/`flutter test` 均在**干净的 detached worktree**（`git worktree add --detach /tmp/zizai-verify-ca673cc ca673cc`）上完成；主工作树的 WIP 未被触碰。
- 未修改任何代码/任务状态文件，仅新增本报告；未触碰 backlog.md，非阻塞发现已列于报告，由计划循环侧追加。
- 主工作树另有未跟踪目录 `output/`（与本任务无关，未触碰）。

## 建议后续动作（blocked → 修复 → 同分支 re-verify）

- 修复：`saveDocument` 事务提交后触发 `onMutation`（如事务内收集脏实体、事务外回调，或给 `_markDirtyOn` 补事务外回调），使「保存防抖 30s 推送」对文档保存生效；并补一条单测（保存 → 不等 debounce 直接触发或 fake 时钟推进 30s → 断言 push 发生且清脏）。
- 其余 Objective 与 77 用例已绿，修复后重跑 `flutter analyze` + `flutter test` 即可 re-verify 放行。

---

## re-verify（commit `7e79f3a`）—— 结论：**pass** ✅

- 评审对象：commit `7e79f3a` 的阻塞项修复部分（`lib/core/db.dart`：saveDocument 事务提交后补 `onMutation?.call()`；`test/core/sync/sync_client_test.dart`：新增回归用例「保存文档触发 onMutation → 防抖推送链路可达」）。该提交同时包含 sync-ui-003 的 WIP（同步区/状态栏指示等），**不在本次复评范围**，由 sync-ui-003 自己的任务评审覆盖。
- 评审方式：只读代码评审 + 命令链验证。**主工作树存在并发改动**（另一任务的 develop WIP 正落在同一工作树：`lib/core/db.dart` 新增 `schemaVersion()`、`lib/ui/settings_view.dart` +83 行、未跟踪的 `lib/core/update.dart`、pubspec 变更等），为确保结果可归因于 7e79f3a，按首次评审做法在**干净的 detached worktree**（`git worktree add --detach /tmp/zizai-verify-7e79f3a 7e79f3a`）上完成全部命令验证；未修改任何代码文件，仅追加本小节。
- 日期：2026-08-06

### 阻塞项修复确认 ✅

1. **saveDocument 事务提交后触发 onMutation（txn 外、提交后）**：事务体内仍用 `_markDirtyOn(txn, id)` 标脏（事务内不能再开 `_db` 事务，db.dart:403），`await _db.transaction(...)` 返回后、事务作用域外调用 `onMutation?.call()`（db.dart:420-421）。无嵌套事务问题；文档不存在抛 `LibraryException` 时事务回滚、421 行不执行，不会误触发回调。✅
2. **pull 应用路径不触发 onMutation（无推送回环）**：`applyCloudDocument`（db.dart:612-639）、`applyCloudNotebook`（db.dart:642-664）、`removeEntityNoDirty`（db.dart:667-669）、`touchPulled`（db.dart:573-579）、`upsertStat`（db.dart:598-609）、`clearDirty`（db.dart:563-570）均不调用 onMutation；`_applySettings` 走 `setSetting(..., syncDirty: false)`。db.dart 全文 onMutation 调用点仅 2 处：`_markDirty`（db.dart:170，非事务写路径）与 saveDocument 提交后（db.dart:421）。引擎侧另有一层双保险：onMutation handler 带 `_applying` 抑制（pull 应用期间不调度推送，client.dart:82-84）。✅
3. **回归测试真实覆盖「saveDocument → onMutation 被调用」**：sync_client_test.dart:184-199 先 createNotebook/createDocument（这两步经 `_markDirty` 也会触发回调），捕获 `before = notified` 后再 saveDocument，断言 `notified > before` —— 精确隔离 saveDocument 的贡献，是真实可失败的回归用例（在修复前该断言必失败）。✅

### 验证命令结果（detached worktree @ 7e79f3a）

| 命令 | 结果 |
|---|---|
| `flutter pub get` | 成功（与 7e79f3a 的 pubspec.lock 一致） |
| `flutter analyze` | `No issues found!` |
| `flutter test` | `All tests passed!`（+83，共 83 用例：原 77 + sync 回归 1 + sync-ui-003 的 ui/sync_test.dart 5） |

说明：主工作树内跑 analyze/test 会混入并发 WIP（曾观察到未跟踪 `update.dart` 的瞬时 error 与 1 条 info lint），均与本提交无关；隔离 worktree 上 7e79f3a 自身 analyze 零问题。

### 剩余不确定性（非阻塞）

1. 「save → 30s 防抖定时器到期 → push → 清脏」完整链路未用 fake 时钟做端到端断言；当前覆盖为：db 契约（saveDocument→onMutation 被调用，本回归用例）+ 引擎挂接（onMutation handler→schedulePush→Timer，client.dart:82-84/119-122）+ push 成功清脏（既有用例「推送后清脏」）。链条每环均有测试、未发现断点，可接受。
2. 本提交内 sync-ui-003 WIP 未复评，留待其任务。
3. 非阻塞发现 1–7 项维持原状，未在本提交修复（`const ziZaiSettings = Settings;` 死代码在 sync_client_test.dart:225 仍存在；db.dart:1 顶部注释过时问题仍存）。复评期间主工作树出现并发 WIP（未跟踪 `lib/core/update.dart` 等，疑似另一任务），与本提交无关、未触碰。

### 结论

阻塞项已修复且回归测试真实覆盖，`flutter analyze` 无 error、`flutter test` 83/83 通过 → **sync-engine-002 复评 pass，可放行 merge**。
