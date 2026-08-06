# Review sync-worker-001-1 — CF Worker 网关 + R2

- 评审对象：commit `a83c174`（`worker/src/index.ts` 174 行、`worker/wrangler.toml`、`worker/README.md`、`worker/test/sync.test.ts` 12 用例、`worker/package.json`/`tsconfig.json`/`vitest.config.ts`/`.gitignore`/`package-lock.json`，共 9 文件）
- 依据：docs/plan/tasks/sync-worker-001.md（Objective 4 项 + Verification）；docs/app/sync.md §2–§4（薄网关、R2 对象布局、envelope、协议 v1、鉴权、服务器时间）；docs/app/update.md §1（版本体系）
- 评审方式：只读代码评审 + 命令链验证；未修改任何代码文件，仅新增本报告
- 日期：2026-08-06

## 结论：pass

Objective 4 项全部达成，与 docs/app/sync.md §2–§4 及 update.md §1 的 contract 一致；无残留 stub/mock（测试用 miniflare 内存 R2 为真实 Worker 绑定注入点，非 mock 实现）。`tsc --noEmit` 无错误；vitest 12/12 通过；`wrangler deploy --dry-run` 编译通过且确认 `ZIZAI_BUCKET` 绑定。非阻塞发现 4 条建议追加 backlog。

## 验证命令结果

| 命令 | 结果 |
|---|---|
| `npx tsc --noEmit`（worker/） | 无错误 |
| `npx esbuild src/index.ts --bundle --format=esm --outfile=dist/index.mjs` | 成功（dist/index.mjs 4.4kb） |
| `npx vitest run` | `1 passed` / `12 passed (12)` |
| `npx wrangler deploy --dry-run` | 编译通过；`env.ZIZAI_BUCKET (zizai) R2 Bucket` 绑定可见；dry-run 退出 |

## 逐项证据

### Objective 1 — `worker/src/index.ts`：push/pull 端点 ✅

- **push 鉴权**：`authorized()`（index.ts:73-78）要求 `Authorization: Bearer <token>`，token 与 `env.SYNC_TOKEN`（Worker secret 环境变量）常量时间比较（`tokenEquals` index.ts:64-71，先比长度再 XOR 累加，无提前返回短路）；无 token / 错 token → 401 `{error:'unauthorized'}`。测试 1、2 ✅
- **协议/版本协商**：`X-Sync-Protocol !== '1'` → 409 `protocol_mismatch`（index.ts:92-94）；请求体 `schemaVersion !== 1` → 409 `schema_mismatch`（index.ts:100-102）。sync.md §4「不匹配返回 409，客户端提示升级 App」✅。测试 3、4 ✅
- **R2 覆盖写（LWW）**：逐 blob `ZIZAI_BUCKET.put(key, ...)`（index.ts:112-114），put 即覆盖；测试「LWW：同一文档二次推送覆盖」断言第二版来自 dev-b 且入库 ✅
- **服务器时间戳**：`serverTime = Date.now()`，所有 blob `updatedAt` 强制覆写为服务器时间（index.ts:104,109），不接受客户端时钟；响应 `{serverTime, applied:[{id, updatedAt}]}`（index.ts:117）。测试断言客户端传 1/999999 均被覆盖 ✅
- **pull**：`updatedAt > since` 过滤（index.ts:149-155）+ 分页游标处理截断（index.ts:137-158）+ `{serverTime, blobs}`（index.ts:160）。测试 5（since=0 全量 / since 最新为空 / 增量过滤）✅
- **envelope 校验**：`isEnvelope()`（index.ts:41-54）校验 t（白名单 doc/notebook/settings/stats）、id、data、deleted、device、schemaVersion 类型；非法跳过不入库（index.ts:107-111）。测试「非法 envelope 被跳过」✅
- **tombstone**：`deleted:true` 的 envelope 正常推送入库、正常随 pull 返回（无过滤），测试 ✅（sync.md §3「删除 = tombstone，拉取方据此删除本地行」）

### Objective 1 续 — R2 键布局 / envelope 结构（sync.md §3）✅

- `keyFor()`（index.ts:26-39）与 sync.md §3 布局逐字一致：`zizai/db/docs/{id}.json`、`zizai/db/notebooks/{id}.json`、`zizai/db/settings.json`、`zizai/db/stats.json`（settings/stats 为固定键整对象，符合设计）。测试断言落键 `zizai/db/docs/layout-1.json` ✅
- Envelope 字段与 sync.md §3 示例一致（t/id/data/deleted/updatedAt/device/schemaVersion，index.ts:4-12）；`meta/manifest.json` 未实现——任务 Objective 与 sync.md §4 接口表均未要求，非本任务范围（设计中的占位项，可由后续任务实现）

### Objective 2 — `worker/wrangler.toml` ✅

- R2 绑定：`[[r2_buckets]] binding="ZIZAI_BUCKET" bucket_name="zizai"`（wrangler.toml:7-9），dry-run 实测可见
- secret 声明：SYNC_TOKEN 不硬编码，注释明确「用 `wrangler secret put SYNC_TOKEN` 设置」（wrangler.toml:11）——与 sync.md §7「Worker 端 secret 环境变量」一致
- 路由：`workers_dev = true`（wrangler.toml:4），README 部署后 URL 为 `https://zizai-sync.<account>.workers.dev`。未配置自定义域名 route——workers.dev 路由满足当前单用户契约，见非阻塞 1

### Objective 3 — `worker/README.md` 部署步骤与 token 轮换 ✅

- 步骤齐全且顺序正确：`wrangler login` → `wrangler r2 bucket create zizai` → **开启对象版本控制**（Dashboard → R2 → zizai → Settings → Versioning → Enable，含 rclone 备选）→ `wrangler secret put SYNC_TOKEN` → `wrangler deploy`（README.md:12-27）
- token 轮换说明两处：部署步骤第 4 步「轮换 = 重新执行本命令即作废旧 token」+ 安全章节「`wrangler secret put SYNC_TOKEN` 重新设置即作废旧值」（README.md:23,43）——与 sync.md §7「token 泄露 = 数据可读：轮换 = 换 Worker secret 即作废旧 token」一致
- 接口表（push/pull 请求响应）与协议 §4 一致；envelope 指向 sync.md §3

### Objective 4 — 安全 ✅

- 不记录内容日志：`worker/src` 全文 0 处 `console.*`（grep 验证）；Worker 无任何请求内容输出
- 错误响应不含敏感信息：所有错误为固定字符串（`unauthorized` / `protocol_mismatch` / `schema_mismatch` / `bad_request` / `not_found`），不回显 token、不回显请求体；测试「未知路径 → 404 响应不含 token/Bearer」显式断言 ✅

### Verification（任务定义测试项）✅

任务 Verification 要求的 4 类用例全覆盖：push 校验（无 token/错 token/schemaVersion 超限 → 拒绝）、pull since 过滤、LWW 覆盖、409 协议不匹配——另有 tombstone、键布局、非法 envelope 跳过 3 类补充（sync.test.ts 12 用例全过）。

## 非阻塞发现（建议追加 backlog）

1. **未配置自定义域名 route**：wrangler.toml 仅 `workers_dev = true`；如需自有域名（如 `sync.zizai.example`）需后续加 `[[routes]]`（custom_domain 或 zone route）。当前 workers.dev 满足单用户契约，README 文档一致，非阻塞。
2. **`isEnvelope` 运行时未校验 `updatedAt` 类型**：push 侧由服务器覆写兜底、pull 侧有显式 `typeof envelope.updatedAt === 'number'` 过滤（index.ts:151），双保险无实际风险；建议后续在 `isEnvelope` 中补齐字段级校验并加注释，减少「接口字段声明 number 但校验缺失」的认知负担。
3. **pull 对损坏对象静默跳过**：JSON.parse 失败/非法 envelope 一律 `continue`（index.ts:147,149），符合「非法跳过」设计，但无任何可观测性（不记内容日志的前提下，可在协议响应中加 `skipped` 计数，客户端无需感知）；当前行为正确，纯增强项。
4. **测试覆盖缺口（次要）**：miniflare 内存 R2 无法验证真实 bucket 的对象版本控制（README 已明确须在真实 bucket 开启，属部署动作）；`notebooks/settings/stats` 三类键布局无专门测试（`docs/` 有，`keyFor` 为纯函数可直接补）；`X-Sync-Protocol` 非数字值（如 `v1`）路径未覆盖（实现 `!== '1'` → 409，行为正确）。

## 范围说明

- 本评审未修改任何代码/任务状态文件，仅新增本报告（docs/plan/reviews/sync-worker-001-1.md）；未触碰 backlog.md，非阻塞发现已列于报告，由计划循环侧追加。
- 工作树存在无关未跟踪目录 `output/`（与本任务无关，未触碰）。
- 依赖已安装（node_modules 存在），`npm install` 未重复执行。

## 建议后续动作

- pass → merge a83c174 到 main → 全量测试 → sync-worker-001 置 done（后续同步引擎任务依赖本端点契约）。
- 非阻塞 1（自定义域）待正式上线时处理；4（键布局/协议非数字值测试）可随 sync-engine 任务补。
