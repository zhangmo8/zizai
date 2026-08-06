# 云备份设计（全量上传备份 / 下载解析恢复）

Status: Draft（v2：备份模型，取代 v1 的 worker 增量同步）
配套：docs/app/update.md（版本体系）、docs/app/README.md（数据模型）

## 1. 目标与原则

- **本地优先**：本地 SQLite 是主存储；云端是全量备份与跨设备通道；无网络照常写作。
- 单用户多设备（macOS / Windows / Android），无协作需求。
- **永不丢字**：恢复前本地 db 文件自动 `.bak`（滚动保留 3 份）；R2 对象版本控制留云端历史。
- **不要服务端**：无 Worker、无自建服务；App 直连 Cloudflare R2（S3 兼容 API）。

## 2. 架构

```text
设备 A ──全量快照(JSON)──► R2 Bucket（对象版本控制开启）
设备 B ──下载快照──► 校验 ──► 本地 .bak ──► 全量导入
```

| 决策 | 理由 |
|---|---|
| R2 直连（S3 API） | 用户指定 CF 存储；免 egress、免费档（10GB）单用户绰绰有余；对象版本控制 = 云端天然历史 |
| 全量快照而非增量 | 备份语义简单可预期：上传 = 全量覆盖，下载 = 全量恢复；无冲突仲裁、无 tombstone、无游标 |
| SigV4 自签（Dart） | 只需 PUT/GET 两个操作，`crypto` 包实现签名；不引入重依赖、不暴露云密钥给第三方 |
| 凭据存本地 settings | `backup.*` 键仅存本机；快照导出时剔除（见 §5） |

## 3. 快照格式（R2 对象 `zizai-backup.json`）

```json
{
  "format": "zizai-backup",
  "version": 1,
  "schemaVersion": 2,
  "createdAt": 1750000000000,
  "device": "mac-abc123",
  "appVersion": "1.0.0",
  "data": {
    "notebooks": [{ "id": "nb-…", "name": "诗集", "position": 0, "createdAt": 1, "updatedAt": 2 }],
    "docs": [{ "id": "doc-…", "notebookId": "nb-…", "title": "静夜思",
               "content": "[{\"insert\":\"床前明月光\\n\"}]", "words": 5,
               "position": 0, "createdAt": 1, "updatedAt": 2 }],
    "settings": { "theme": "dark", "dailyGoal": "3000" },
    "stats": { "2026-08-06": 1200 }
  }
}
```

- 文档 `content` 为 Quill Delta JSON 字符串（与本地一致，解析端直接落库）。
- 恢复校验：`format` 必须是 `zizai-backup`；`version > 当前` 拒绝（需升级 App）；
  `schemaVersion > 本地` 拒绝（需先升级）。

## 4. 上传与恢复

| 操作 | 流程 |
|---|---|
| 上传备份（手动） | 全量导出 → `PUT zizai-backup.json`（覆盖写，R2 版本控制留历史） |
| 下载恢复（手动+二次确认） | `GET zizai-backup.json` → 校验 → 本地 db 文件 `.bak`（滚动 3 份）→ 事务内清空各表重建 |

- 恢复为**全量替换**：以云端快照为唯一基准；本地现状由 `.bak` 兜底。
- 恢复成功后刷新 Library/Settings 控制器（设置页可见即时生效）。
- 失败仅提示，不打断写作；状态栏指示 `● 已备份 / ⟳ 备份中 / ⚠ 失败 n 次`。

## 5. 安全

- 凭据：R2 Account ID / Bucket / Access Key / Secret，存本地 settings 表
  （`backup.*`），设置页掩码输入；**快照导出剔除全部 `sync.*` / `backup.*` 键**（密钥绝不离开本机）。
- HTTPS only；SigV4 每次请求独立签名（时间戳防重放）。
- 凭据泄露 = 云端备份可读：轮换 = R2 重新生成密钥即作废旧凭据。

## 6. 测试

- 快照往返：种子库导出 → 新库导入 → 各表一致；`sync.*`/`backup.*` 键不出现。
- 非法快照拒绝：坏 JSON / 非备份格式 / 未来版本。
- S3Store：SigV4 签名与独立实现（Python）基准一致；PUT/GET 往返；404 → null。
- 恢复前 `.bak` 生成。
- 未配置凭据：上传/下载 no-op。

## 7. 变更记录

- v2（备份模型）：删除 worker 增量同步（`lib/core/sync/`、`worker/`），改全量快照
  上传/恢复；CI 移除 npm/worker 依赖。
- v1（已废弃）：Worker + R2 增量 push/pull、LWW、tombstone、sync_journal 脏标记
  （表保留但不再使用；不做 schema 回退迁移）。
