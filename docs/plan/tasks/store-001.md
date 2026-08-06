# Task store-001 — 数据层（含迁移链）

```yaml
id: store-001
scope: lib/core
status: pending
depends-on: [env-001]
```

## Objective

实现 `lib/core/` 全部模块：

1. `models.dart`：`Notebook` / `Document` / `Settings` 数据类与（反）序列化。
2. `word_count.dart`：纯函数 `wordCount(String) → int`（规则见 docs/app/ui-editor.md）。
3. `db.dart`：
   - schema v1 创建 + `PRAGMA user_version = 1`；
   - **迁移链框架**（docs/app/update.md §2）：`migrations` 有序数组、`onUpgrade` 逐级执行、升级前备份 `.bak`（滚动 3 份）、迁移失败抛可恢复错误（调用方停止启动提示）；
   - 笔记本/文档 CRUD（含 `ON DELETE CASCADE` 验证）、`position` 上移/下移、按 position 排序查询；
   - settings KV、stats 日增量（负数不越界）、last_open 读写；
   - `saveDocument()` 返回本次字数增量并同步字数快照；
   - 错误统一 `LibraryException{message, path}`，不吞异常；db 打开失败抛可恢复错误。
4. `export.dart`：`exportPlainText(Document) → String`（Delta → 纯文本）。

## Context

- docs/app/README.md（§4 数据模型、§5）
- docs/app/update.md（§2 DB 版本与迁移）
- docs/app/ui-editor.md（Word Count 规则）
- docs/plan/analysis/requirements.md（F1–F3、F8.2、NFR）

## Path

- `lib/core/*.dart`
- `test/core/*.dart`

## Verification

- 单测：CRUD 各路径；级联删除；增量正/负/跨日；字数中英标点；**迁移回放**（v1 空库逐级升到当前版本，断言 schema/数据无损）；迁移失败注入 → `.bak` 可恢复；settings 损坏回退默认。
- 错误路径：db 文件损坏抛可恢复错误。
- `flutter analyze` 无错误。
