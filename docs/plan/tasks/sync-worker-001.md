# Task sync-worker-001 — CF Worker 网关 + R2

```yaml
id: sync-worker-001
scope: worker/
status: pending
depends-on: [env-001]
```

## Objective

按 docs/app/sync.md §2–§4 实现云同步服务端：

1. `worker/src/index.ts`：
   - `POST /sync/push`：Bearer token 校验（Worker secret 环境变量）→ 校验请求体 schemaVersion 与 `X-Sync-Protocol`（不匹配 409）→ R2 覆盖写（LWW）→ 返回 `{serverTime, applied:[{id, updatedAt}]}`；
   - `POST /sync/pull`：返回 `updatedAt > since` 的 blobs + `{serverTime}`；
   - 所有时间戳由服务器签发（`Date.now()`），不接受客户端时钟。
2. `worker/wrangler.toml`：R2 bucket 绑定（`ZIZAI_BUCKET`）、secret 声明（`SYNC_TOKEN`）、路由。
3. `worker/README.md`：部署步骤——`wrangler login` → 创建 bucket → **开启对象版本控制** → `wrangler secret put SYNC_TOKEN` → `wrangler deploy`；含 token 轮换说明。
4. 不记录内容日志；错误响应不含敏感信息。

## Context

- docs/app/sync.md（整体）
- docs/app/update.md（§1 版本体系）

## Path

- `worker/**`
- `docs/plan/build-windows.md` 之外的部署文档即 `worker/README.md`

## Verification

- Worker 单测（vitest + 内存 R2 mock）：push 校验（无 token/错 token/schemaVersion 超限 → 拒绝）、pull since 过滤、LWW 覆盖、409 协议不匹配。
- `worker/README.md` 可按步骤部署到真实 CF 账号（部署动作由用户执行）。
