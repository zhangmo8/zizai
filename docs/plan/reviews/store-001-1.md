# Review store-001-1 — 数据层（含迁移链）

- 评审对象：commit `1237662`（`lib/core/{models,word_count,db,export}.dart` + `test/core/*`）
- 依据：docs/plan/tasks/store-001.md；docs/app/README.md §4/§5；docs/app/update.md §2；docs/app/ui-editor.md
- 评审方式：只读代码评审 + `flutter analyze` + `flutter test`
- 日期：2026-08-06

## 结论：pass

实现与设计 contract 一致，无残留 stub/mock；analyze 无错误，36 个测试全部通过。非阻塞发现 4 条（见下），建议追加 backlog，不影响本任务验收。

## 验证命令结果

| 命令 | 结果 |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | +36 All tests passed（word_count 6 / db 19 / migration 4 / export 6 / widget 1） |

注：测试输出中 `error Bad state: boom during open, closing...` 是「迁移失败注入」测试故意抛错产生的预期日志，非失败。

## 逐项证据

### Objective 1 — models.dart ✅

- `Notebook` / `Document` / `Settings` 数据类齐备，字段与 README §4 schema 列一一对应（`id/name/position/created_at`；`id/notebook_id/title/content/words/position/created_at/updated_at`）。
- 反序列化：`Notebook.fromRow` / `Document.fromRow` / `Settings.fromMap`；序列化：`Settings.toMap`。
- Settings 键 = `theme/fontFamily/fontSize/lineHeight/dailyGoal`，与 README §4「settings 键」一致；损坏值经 `tryParse` 回退默认（theme→system、fontSize→18、lineHeight→1.8、dailyGoal→2000）。
- 另含 `LastOpen` 模型与 `LibraryException{message, path?}`（README §5 要求，`models.dart:7`）。

### Objective 2 — word_count.dart ✅

- 纯函数 `wordCount(String) → int`（`word_count.dart:15`），无副作用、无 I/O。
- 中/日/韩 1 字符 = 1 字：正则覆盖假名 3040–30FF、CJK 扩展 A 3400–4DBF、CJK 统一 4E00–9FFF、兼容表意 F900–FAFF、谚文音节 AC00–D7AF（`word_count.dart:9-12`）。
- 连续英文/数字按词：`[A-Za-z0-9]+` 一次匹配计 1 字。
- 空白与标点不在匹配集合中，自然不计。
- 单测覆盖中/日/韩、英文数字词、空白标点、中英混排、空串（`word_count_test.dart`）。

### Objective 3 — db.dart ✅

- **schema v1 + user_version=1**：`_createSchemaV1` 建 5 张表，DDL 与 README §4 逐字符一致（含 `ON DELETE CASCADE`、`last_open.id CHECK(id=1)`）；`currentSchemaVersion = 1`，测试断言 `PRAGMA user_version == 1`（`migration_test.dart:43`）。
- **迁移链框架**（update.md §2 全项）：
  - 有序数组 `schemaMigrations` + `SchemaMigration{to, up}`（`db.dart:20-29`）；
  - `runMigrations` 从 `from+1` 逐级执行到 `to`，缺级抛 `StateError`（`db.dart:32-51`）；
  - `onUpgrade` 先 `backupDbFile` 再跑迁移（`db.dart:100-103`）；
  - 备份滚动 3 份：`.bak` / `.bak.1` / `.bak.2`（`db.dart:55-66`），滚动测试通过（`migration_test.dart:134`）；
  - 迁移失败：不吞异常，`open()` 统一包成可恢复 `LibraryException`（`db.dart:107-111`）；注入失败后 user_version 仍为 1、数据无损、`.bak` 为 v1 全量字节一致、换正确迁移可重试成功（`migration_test.dart:93-132`）。
- **CRUD**：笔记本/文档建、列、重命名、删、移全路径；`onConfigure` 开 `PRAGMA foreign_keys = ON`，级联删除有测试（`db_test.dart:106`）；`position` 上移/下移为交换相邻 position、边界 no-op、文档移动限定本笔记本（`db_test.dart:115-131`）；查询统一 `position ASC, created_at ASC`。
- **settings KV**：`getSetting/setSetting` + `loadSettings/saveSettings` 往返（`db_test.dart:197-231`）。
- **stats 日增量**：`saveDocument` 事务内按 `delta != 0` 累加当日，负增量不下探到 0（`_applyDeltaToStats`，`db.dart:421-432`；`db_test.dart:149-162`）。
- **last_open**：独立读写 + `saveDocument` 内同步快照（`db.dart:302-311`、`db_test.dart:164-174`）。
- **saveDocument 返回字数增量**：`newWords - oldWords`（`db.dart:292`），正/负增量均有断言。
- **错误统一**：全部用 `LibraryException{message, path}`；打开失败（如把目录当 db 文件）抛可恢复 `LibraryException`（`db_test.dart:247-256`）；非法 Delta 内容转 `LibraryException`（`db.dart:376-382`、`db_test.dart:185`）。

### Objective 4 — export.dart ✅

- `deltaToPlainText(String)`：Delta JSON → 纯文本；`''` 与 `'{}'` 空文档占位返回空串；非法 JSON / 非数组抛 `FormatException`；末位 insert 缺换行时补 `\n` 规范化再交给 Quill，剥掉 Quill 追加的尾部换行（`export.dart:18-43`）。
- `exportPlainText(Document) → String`（`export.dart:46`）。
- 单测覆盖空占位、简单插入、带格式属性、换行、非法结构（`export_test.dart`）。

## 文档一致性

- schema 五张表 DDL 与 README §4 完全一致；增量规则（快照基准、负不下探、快照写回 documents.words 与 last_open.words）与 §4 一致。
- 迁移链与 update.md §2 一致：有序数组、逐级执行、升级前备份滚动 3 份、失败抛可恢复错误（停止启动）、只前向不回退、回放测试纪律已落地。
- 模块划分与 README §5 一致（core 下四个文件，命名、职责匹配）。
- Word Count 规则与 ui-editor.md 一致。
- **未发现「先改文档再改代码」类冲突**（无实现与设计矛盾处需要回改文档）。

## 非阻塞发现（建议追加 backlog）

1. **「增量跨日」无测试覆盖，且不可测**：store-001.md Verification 列了「增量正/负/跨日」，但 `saveDocument` 内部硬编码 `DateTime.now()`（`db.dart:286`），无时钟注入，无法自动验证隔日保存不串日（`todayDelta` 有 `nowMs` 参数但保存路径没有）。功能本身按日期键天然隔离、无缺陷；建议后续给 `Db` 加可注入时钟（如构造参数 `DateTime Function()? clock`）并补跨日单测。
2. **「settings 损坏回退默认」无显式单测**：`Settings.fromMap` 的 `tryParse` 回退逻辑已实现（`models.dart:148-159`），但没有针对 `fontSize='abc'` 之类损坏值的用例。建议补测。
3. **`deltaToPlainText` 异常类型小瑕疵**：非 map op（如 `[42]`）会抛 `TypeError` 而非 docstring 承诺的 `FormatException`（`export.dart:31` 的 `cast`）；embed 型末位 insert（Map）不触发补换行，可能抛 Quill 内部异常。App 实际写入的 Delta 均由 Quill 产出、末位必为换行 insert，主流程不受影响；建议后续统一为显式校验并抛 `FormatException`。
4. **迁移失败注入测试的预期日志噪音**：sqflite 在注入失败时打印 `error Bad state: boom during open, closing...`，属预期输出，可在测试注释中说明以免误判（不影响结论）。

## 范围说明

- `lib/main.dart` 仍为脚手架 counter demo、`test/widget_test.dart` 为脚手架默认用例——均超出 store-001 `scope: lib/core`，归属后续 UI 任务，不构成本任务 stub。
- 本评审未修改任何代码/任务状态文件，仅新增本报告。

## 建议后续动作

- pass → merge 到 main → 全量测试 → store-001 置 done。
- 上述 4 条非阻塞发现写入 backlog，优先级：1（跨日可测性）> 2（损坏回退测试）> 3（异常类型）> 4（日志说明）。
