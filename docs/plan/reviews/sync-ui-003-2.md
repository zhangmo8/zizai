# Review sync-ui-003-2 — 备份设置区与状态栏备份指示（v2 规格收口）

- 评审对象：v2 重写后的 sync-ui-003（docs/plan/tasks/sync-ui-003.md）——备份 UI 实现随
  备份模型迁移已在库中，本次收口新增 `test/ui/backup_test.dart`（7 断言组 / 6 用例）
  与两处小修：状态栏指示新增「未备份」中性态（`lib/ui/status_bar.dart`）、指示器改为
  监听 `Listenable.merge([backup, state, lastBackupAt, failureCount])`。
- 依据：docs/app/ui-settings.md（§备份）、docs/app/ui-shell.md（指示规则，含本次补充的
  「未备份」态）、docs/app/sync.md v2、docs/app/style.md。
- 旧评审 sync-ui-003-1 针对已删除的 `lib/core/sync/`（Worker 模型），其 B1/B2 随代码
  删除失效，不再适用。
- 日期：2026-08-13

## 结论：pass

## 逐项核对

| 规格项 | 证据 |
|---|---|
| 凭据四项输入、保存到 settings 表 `backup.*`、重开回填 | backup_test「凭据输入保存」：提交后 `db.getSetting` 断言 + 重开设置页回填断言 |
| Secret 掩码 | 同上：`TextField.obscureText == true` |
| 未配置：按钮禁用 + 引导文案 + 指示隐藏 | backup_test「未配置凭据」：`ZzButton.onPressed == null`、引导文案、`cloud_outlined` 不出现 |
| 立即备份：成功刷新「上次备份」+ toast | backup_test「立即备份成功」（MockClient 200） |
| 失败：错误文案 + 重试按钮 + 指示「失败 n 次」 | backup_test「备份失败」（MockClient 500）：`failureCount == 1`、tooltip「失败 1 次」 |
| 下载恢复二次确认（.bak 提示可见），取消不发请求、不动库 | backup_test「下载恢复」：确认框含 `.bak`、`getCalled == 0`、文档保留 |
| 指示四态渲染（未备份/备份中/已备份/失败） | 「立即备份成功」内覆盖未备份→备份中→已备份，「备份失败」覆盖失败态 |
| 指示点击定位设置页备份区 | backup_test「状态栏指示点击」 |
| `flutter analyze` | No issues found |
| `flutter test` | 全量 123 用例通过 |

## 非阻塞发现

- 测试收尾需 `settleAsync + pump(6s)` 释放挂起计时器（editor 内有 5s 计时器），
  属测试基建噪音，可随 backlog #25（偶发 flake）一起看。
