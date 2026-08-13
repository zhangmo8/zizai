# Task sync-ui-003 — 备份设置区与状态栏备份指示

```yaml
id: sync-ui-003
scope: lib/ui
status: done
depends-on: [set-004, sync-engine-002]
```

> v2 重写：原 Worker 时代规格（云同步开关 / 令牌输入 / 立即同步）已随备份模型作废，
> 旧评审 sync-ui-003-1 针对的 `lib/core/sync/` 代码已删除，其 blocking 不再适用。
> 备份 UI 主体实现已随备份模型迁移落地（见「现状」），本任务收口 = 对照本规格补齐
> UI 测试并走 verify 流程。

## Objective

按 docs/app/ui-settings.md（§备份区）与 docs/app/ui-shell.md（状态栏备份指示）实现：

1. 设置页「备份」分类（仅 `BackupManager` 接线时显示）：
   - R2 凭据四项：Account ID / Bucket / Access Key / Secret Key（Secret 掩码，仅存本地
     settings 表 `backup.*` 键，快照导出剔除）；
   - 「上次备份」只读状态 + 「立即备份」按钮（进行中 loading，失败显示错误 + 重试）；
   - 「下载恢复」按钮：二次确认（提示覆盖本地、`.bak` 兜底）→ 恢复后刷新
     Library/Settings 控制器 + toast。
2. 状态栏备份指示：`● 已备份 / ⟳ 备份中 / ⚠ 失败 n 次`（色值按 style.md：accent /
   text-secondary / danger）；点击进入设置页备份区；未配置凭据时不显示。
3. 恢复安全提示：恢复前本地 db `.bak`（滚动 3 份）的兜底路径对用户可见（确认框文案）。

## 现状

`lib/ui/settings_view.dart`（`_backupPage` / `_backupActions`）与 `lib/ui/status_bar.dart`
（`_BackupIndicator`）已实现上述交互；缺 UI 测试覆盖。

## Context

- docs/app/sync.md（v2 备份模型，整体）
- docs/app/ui-settings.md（§备份区、State Variants）
- docs/app/ui-shell.md（状态栏备份指示）
- docs/app/style.md（§3 tokens、§9 状态色）

## Path

- `lib/ui/settings_view.dart`、`lib/ui/status_bar.dart`
- `test/ui/backup_test.dart`（新增）

## Verification

- widget test（内存 db + mock S3Store）：凭据保存回填、Secret 掩码；立即备份成功后
  「上次备份」刷新；备份失败显示错误 + 重试；下载恢复走二次确认且取消不动库；
  未配置凭据时状态栏指示隐藏、配置后三态渲染正确；指示点击定位设置页备份区。
- `flutter analyze` 无错误，`flutter test` 全量通过。
