# Task snap-001 — 本地版本快照

```yaml
id: snap-001
scope: lib/core + lib/ui
status: done
depends-on: [integ-005]
```

## Objective

本地快照留底与回滚（复用备份模型的快照格式，粒度到单文档）：

1. `core/snapshot_history.dart`（或并入 `core/backup/`）：
   - 触发：文档保存时若距上次快照删改超过阈值（如净删除 ≥ 200 字或 30 分钟首次改动），
     自动留存该文档的 Delta 快照；手动「留存快照」入口；
   - 存储：本地 `snapshots` 表（docId / createdAt / words / content Delta），
     每文档滚动保留 N 份（默认 20，可清理）；
   - 迁移链新增表版本（走 store-001 框架）。
2. UI：文档级「历史快照」面板 —— 快照列表（时间 + 字数），预览只读渲染，
   「回滚到此版本」二次确认（回滚前当前版本先自动留快照，永不丢字）。
3. 对比视图可后置（backlog）：先做纯预览 + 回滚。

## Context

- docs/app/sync.md（快照格式；本任务开始前在 docs/app/ 补「本地快照」设计章节）
- docs/app/README.md（数据模型、迁移链）

## Verification

- 单测：阈值触发/不触发、滚动保留上限、回滚往返一致、回滚前自动留底。
- widget test：列表渲染、回滚确认、取消不动库。
- `flutter analyze` / `flutter test` 通过。
