# 更新机制与版本体系

Status: Draft
配套：docs/app/sync.md（云同步）、docs/app/README.md（数据模型）

## 1. 版本体系（三套版本，各司其职）

| 版本 | 含义 | 存放 | 谁在变 |
|---|---|---|---|
| App 版本 | 客户端发布版本，语义化 `1.2.0` | pubspec `version` + 更新清单 | 每次发布 |
| DB schema 版本 | 本地库结构版本，自增整数 | `PRAGMA user_version` | 仅 schema 变更 |
| 同步数据版本 | 云 blob 结构与协议版本 | `X-Sync-Protocol` 头 + blob `schemaVersion` | 仅云协议变更 |

演进规则：App 发布时可以携带新的 DB schema 版本与同步数据版本；三者独立增长，由更新清单映射关系。

## 2. DB 版本与迁移机制

### 机制

- 打开库：`openDatabase(version: <当前代码 schema 版本>, onUpgrade: 逐级执行)`。
- 迁移链：代码内有序数组 `migrations = [v1, v2, v3, ...]`，每项 `{to: n, up(Database)}`；从 `oldVersion+1` 逐级执行到 `newVersion`。
- 版本写入 `PRAGMA user_version`（SQLite 原生，sqflite 依据它驱动 onUpgrade）。

### 升级前备份与失败处理

- 任何迁移执行前：`zi-zai.db` → `zi-zai.db.bak`（滚动保留最近 3 份）。
- 迁移失败：**停止启动** + 明确错误提示（不静默、不降级运行），用户可手动用 `.bak` 恢复。
- 迁移只前向、不回退；回滚 = 恢复备份文件。

### 纪律

- 任何 schema 变更 = 同一任务内完成「迁移脚本 + 回放测试」，禁止只改建表语句。
- 回放测试：从 v1 空库逐级迁移到当前版本，断言每级 schema 与数据无损。

## 3. App 更新机制（R2 分发）

### 分发结构（同一 R2 bucket）

```text
zizai/apps/update.json
zizai/apps/zizai-1.2.0-macos.zip
zizai/apps/zizai-1.2.0-windows.zip
zizai/apps/zizai-1.2.0.apk
```

### 更新清单 update.json

```json
{
  "latest": "1.2.0",
  "minDbSchema": 4,
  "platforms": {
    "macos":   { "url": "https://.../zizai-1.2.0-macos.zip",  "sha256": "..." },
    "windows": { "url": "https://.../zizai-1.2.0-windows.zip", "sha256": "..." },
    "android": { "url": "https://.../zizai-1.2.0.apk",        "sha256": "..." }
  },
  "notes": "新增云同步；修复自动保存竞态"
}
```

### 检查与安装流程

1. 触发：启动后异步检查一次 + 设置页「检查更新」手动。
2. 比较：`latest > 当前 App 版本` 才提示；自用策略 = **提示式**，不强制、不静默安装。
3. 下载：校验 sha256，失败拒绝安装并报错。
4. 安装：
   - Android：下载 APK → FileProvider 触发系统安装（未知来源提示，自用可接受）。
   - 桌面：下载 zip → 解压替换 app 目录（macOS 同时校验 codesign 状态；未签名 app 需「右键打开」首次运行，文档说明）。
5. 更新后首次启动：若本地 DB schema < `minDbSchema` → 自动执行 §2 迁移链；新功能随迁移解锁。
6. 安装包由 pkg-006 构建并上传 R2（wrangler/rclone 均可，部署说明见 sync-worker 部署文档）。

## 4. 版本一致性约束

| 场景 | 行为 |
|---|---|
| 旧 App + 新 DB blob（schemaVersion 更高） | 拒写 + 提示升级 |
| 新 App + 旧 DB（本地 schema 低于代码） | onUpgrade 自动迁移 |
| 新旧 App 互相同步 | 协议版本不一致 → 409 + 升级提示 |
| 更新清单 minDbSchema > 本地 | 更新安装后首次启动自动迁移 |

## 5. 测试

- 迁移回放：v1 空库 → 当前版本，schema/数据断言。
- 迁移失败注入：中断某级迁移 → 库保持备份可恢复。
- 清单解析：版本比较正确；sha256 不符拒绝安装；下载失败重试。
