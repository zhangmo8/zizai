# zizai-sync Worker（云同步网关）

薄网关：token 校验 + 服务器时间戳 + R2 读写。协议见 docs/app/sync.md §4。

## 部署

前置：Node ≥ 18，`npm install`（含 wrangler / miniflare）。

```bash
cd worker

# 1. 登录 Cloudflare
npx wrangler login

# 2. 创建 R2 bucket（或 Dashboard → R2 → Create bucket，名称与 wrangler.toml 一致：zizai）
npx wrangler r2 bucket create zizai

# 3. 开启对象版本控制（云端修订历史，输家找回兜底）
#    Dashboard → R2 → zizai → Settings → Versioning → Enable
#    或用 rclone 配置后：rclone r2 versioning zizai 见 rclone 文档

# 4. 设置同步令牌（secret 环境变量，轮换 = 重新执行本命令即作废旧 token）
npx wrangler secret put SYNC_TOKEN

# 5. 部署
npx wrangler deploy
```

部署后获得 `https://zizai-sync.<account>.workers.dev`，App 设置页「同步令牌」填
第 4 步设置的 token，同步区即可使用。

## 本地开发与测试

```bash
npm test          # vitest + miniflare（内存 R2），覆盖鉴权/协议/时间戳/LWW/tombstone/键布局
npx wrangler dev  # 本地起服务调试
```

## 安全

- token 校验用常量时间比较；错误响应不含 token/请求体回显。
- 不记录内容日志（Worker 无日志输出内容）。
- token 轮换：`wrangler secret put SYNC_TOKEN` 重新设置即作废旧值（客户端更新令牌后恢复同步）。
- 时间戳一律服务器签发（`Date.now()`），不接受客户端时钟，规避设备时钟偏差。

## 接口

| 接口 | 请求 | 响应 |
|---|---|---|
| `POST /sync/push` | `Authorization: Bearer <token>` + `X-Sync-Protocol: 1`；体 `{deviceId, schemaVersion, blobs:[envelope...]}` | `{serverTime, applied:[{id, updatedAt}]}`；协议/版本不匹配 409 |
| `POST /sync/pull` | 同上；体 `{deviceId, since}` | `{serverTime, blobs:[updatedAt > since 的 envelope...]}` |

envelope 结构见 docs/app/sync.md §3。
