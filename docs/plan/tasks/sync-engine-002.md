# Task sync-engine-002 — Dart 同步引擎

```yaml
id: sync-engine-002
scope: lib/core/sync
status: pending
depends-on: [store-001, sync-worker-001]
```

## Objective

按 docs/app/sync.md 实现客户端同步引擎：

1. `protocol.dart`：envelope 序列化/反序列化、pull/push 请求构造、`X-Sync-Protocol` 与 schemaVersion 协商（409 → 可读错误）。
2. `client.dart`：
   - 本地 `sync_journal` 表（经 store-001 的迁移链加入）：doc_id / 脏标记 / last_pushed_at / last_pulled_at；
   - 推送：脏行 → envelope（内容 Delta、字数、deleted 标记）→ Worker；成功后清脏；
   - 拉取：`since` → 新 blobs → LWW 应用（云端 updatedAt > 本地 → 替换；**输家版本写 `.sync-bak/{docId}.json`**，保留 5 份）；tombstone → 本地软删；
   - settings 整对象 LWW、stats 按 date 键合并；
   - 触发：启动拉取、保存防抖 30s 推送、手动「立即同步」、网络恢复重试（指数退避 30s/1m/5m/上限 1h）；
   - 同步状态机：idle / syncing / error（供状态栏与设置页消费）；
   - **token 永不进入 envelope / push 请求体**（只放 Authorization 头）。
3. 双设备冲突语义（LWW）与备份规则见 sync.md §5。

## Context

- docs/app/sync.md（整体）
- docs/app/update.md（版本协商）
- docs/plan/analysis/requirements.md（F7）

## Path

- `lib/core/sync/*.dart`（+ store-001 迁移链加入 `sync_journal` 表）
- `test/core/sync_test.dart`

## Verification

- 单测（内存 Worker mock）：双设备模拟（A push → B pull 一致）；同文档冲突 → LWW + `.sync-bak` 生成；tombstone 传播；断网重试退避；409 协议不匹配；token 不在请求体中。
- `flutter analyze` 无错误。
