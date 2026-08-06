# 云同步设计（CF 存储为基准：R2）

Status: Draft
配套：docs/app/update.md（版本体系）、docs/app/README.md（数据模型）

## 1. 目标与原则

- **本地优先**：本地 SQLite 是主存储；云是锚点、备份与跨设备通道；无网络照常写作。
- 单用户多设备（macOS / Windows / Android），无协作需求。
- **永不丢字**：任何冲突不得静默覆盖；输家版本保留本地备份，云端靠 R2 版本控制留存历史。

## 2. 架构

```text
设备 A (macOS)  ─┐
设备 B (Windows) ┼─ HTTPS JSON ─► CF Worker（薄网关）─► R2 Bucket（云基准）
设备 C (Android)─┘      │                                   │
                    token 校验/服务器时间/协议版本      对象版本控制开启
```

| 决策 | 理由 |
|---|---|
| R2 为云存储基准 | 用户指定 CF 存储；免 egress、免费档（10GB 存储）对单用户绰绰有余；支持对象版本控制 → 云端天然修订历史 |
| Worker 薄网关 | 免去 App 内嵌 AWS 风格 S3 密钥；服务器签发时间戳（规避设备时钟偏差）；Dart 侧只需 HTTP+JSON |
| 不选 D1 | SQLite 云库虽贴合本地 schema，但免费档库容 500MB、同步逻辑更重；blob 同步更简单可靠 |

## 3. 云数据模型（R2 对象布局）

```text
zizai/db/docs/{docId}.json        # 文档（含 Delta 内容）
zizai/db/notebooks/{nbId}.json    # 笔记本（名、顺序）
zizai/db/settings.json            # 全局设置（整对象 LWW）
zizai/db/stats.json               # 每日字数（按 date 键合并）
zizai/meta/manifest.json          # 协议版本、数据版本、设备数
```

统一 envelope（所有 blob 同构）：

```json
{
  "t": "doc",
  "id": "uuid",
  "data": { "notebookId": "...", "title": "...", "contentDelta": {}, "words": 0 },
  "deleted": false,
  "updatedAt": 1750000000000,
  "device": "mac-abc123",
  "schemaVersion": 1
}
```

- 删除 = tombstone（`deleted: true`），拉取方据此删除本地行。
- `schemaVersion` 见 docs/app/update.md §1 版本体系；客户端遇更高版本 blob → 提示升级，不写入本地。

## 4. 同步协议 v1

| 接口 | 请求 | 响应 |
|---|---|---|
| `POST /sync/push` | `{deviceId, blobs: [envelope...]}` | 服务器校验 token 与 schemaVersion → 覆盖写 R2（LWW）→ `{serverTime, applied:[{id, updatedAt}]}` |
| `POST /sync/pull` | `{deviceId, since}` | `updatedAt > since` 的 blobs + `{serverTime}` |

- 鉴权：`Authorization: Bearer <token>`；token 是 Worker 环境变量 secret，用户在设置页配置。
- 协议版本：请求头 `X-Sync-Protocol: 1`；不匹配返回 409，客户端提示升级 App。
- 时间：一切以服务器时间戳为准；客户端只报告「上次拉取时间」。

## 5. 冲突与合并

| 对象 | 策略 |
|---|---|
| 文档 | 文档级 LWW（`updatedAt` 大者胜） |
| 笔记本 | LWW |
| settings | 整对象 LWW |
| stats | 按 date 键逐条 LWW |

**输家保护**（永不丢字）：
1. 拉取时发现本地文档被云端覆盖且本地更新 → 本地旧版写入 `.sync-bak/{docId}.json`（保留最近 5 份）。
2. R2 对象版本控制开启 → 云端每一版可回滚。
3. 状态栏出现「有本地版本已备份」提示，可从设置页查看备份目录。

## 6. 同步触发与状态机

```text
启动拉取 ─► idle ─► 保存防抖 30s ─► push ─► idle
   │                │
   └── 网络恢复/手动「立即同步」──┘
失败 ─► 指数退避重试（30s / 1m / 5m / 上限 1h）─► idle（保留错误提示）
```

- 同步不阻塞编辑：全部异步，失败仅提示不打断写作。
- 状态栏指示：`● 已同步 / ⟳ 同步中 / ⚠ 失败 n 次`（见 ui-shell.md）。

## 7. 安全

- token 由用户自配：Worker 端 `secret` 环境变量；App 端存本地 settings 表，**永不随同步推送**（push 前剔除 token 字段，并列入代码审查规则）。
- HTTPS only；Worker 不记录内容日志。
- token 泄露 = 数据可读：轮换 = 换 Worker secret 即作废旧 token。
- deviceId：首次启动生成 UUID 存本地，仅作推送来源标记。

## 8. 测试

- 双设备模拟：A 写→push→B pull→内容一致；A 改→B 离线改同文档→冲突→LWW + `.sync-bak` 生成；tombstone 跨设备传播；断网恢复重试。
- 协议版本不匹配 → 409 → 升级提示。
- 同步期间 App 退出/重进，状态不丢失（journal 表）。
