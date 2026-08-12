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
update.json                              ← 根路径，App 始终检查此 URL
releases/v1.2.0/app-release.apk
releases/v1.2.0/zizai-macos.zip
releases/v1.2.0/zizai-windows.zip
releases/v1.2.0/update.json              ← 版本归档
```

构建时通过 `--dart-define=UPDATE_URL=…` 注入默认更新地址，
App 首次启动即可自动检查更新，无需手动配置。
用户仍可在设置页覆盖此地址。

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

## 5. CI/CD 构建（R2 分发）

GitHub Actions 工作流 [build.yml](../../.github/workflows/build.yml) 负责三端打包、
上传 R2、生成 `update.json`，并创建 GitHub Release（仅 release notes）。

- 触发方式：推送符合 `v<major>.<minor>.<patch>` 格式的 tag，或在 Actions 中手动输入**已推送到远程的同格式 tag**。
- 前置校验：工作流会在启动三端构建前验证 tag 格式及其远程存在性；不存在时立即失败，不启动构建 runner。
- 版本校验：tag 的语义版本必须与 `pubspec.yaml` 的 App 版本一致（构建号 `+N` 除外），避免安装后仍重复提示同一更新。
- 正常发布流程：先将 `pubspec.yaml` 的 App 版本更新为对应版本，验证 CI 后执行 `git tag v<version>` 与 `git push origin v<version>`。tag push 会自动触发发布。
- 构建产物上传至 R2（不在 GitHub 产生 artifact 缓存）：
  - 三端包 → `s3://<bucket>/releases/<tag>/`
  - `update.json` → `s3://<bucket>/releases/<tag>/update.json`（归档）+ `s3://<bucket>/update.json`（根路径覆盖，App 始终检查此 URL）
- `update.json` 中的下载 URL 指向 R2 公开域名（`R2_PUBLIC_BASE` secret）。
- 构建时通过 `--dart-define=UPDATE_URL=<R2_PUBLIC_BASE>/update.json` 将默认更新地址注入二进制。
- GitHub Release 仅保留自动生成的 release notes，不再上传二进制资产。
- 上传后必须从 R2 公开域名回读根清单，并对三端安装包执行公开 GET 探针；任一对象不可访问时发布失败。
- macOS Release 的 App Sandbox 必须包含 `com.apple.security.network.client`；Android 正式清单必须包含 `INTERNET` 和 `REQUEST_INSTALL_PACKAGES`。

### 所需 GitHub Secrets

| Secret | 说明 |
|---|---|
| `R2_ACCOUNT_ID` | Cloudflare Account ID |
| `R2_ACCESS_KEY_ID` | R2 API Token Access Key ID |
| `R2_SECRET_ACCESS_KEY` | R2 API Token Secret Access Key |
| `R2_PUBLIC_BASE` | R2 公开访问域名（如 `https://pub-xxxxx.r2.dev`，结尾不带 `/`） |

## 6. 测试

- 迁移回放：v1 空库 → 当前版本，schema/数据断言。
- 迁移失败注入：中断某级迁移 → 库保持备份可恢复。
- 清单解析：版本比较正确；sha256 不符拒绝安装；下载失败重试。
