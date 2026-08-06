# Task sync-ui-003 — 同步设置与状态指示

```yaml
id: sync-ui-003
scope: lib/ui
status: pending
depends-on: [set-004, sync-engine-002]
```

## Objective

按 docs/app/ui-settings.md（同步区）与 docs/app/ui-shell.md（状态栏同步指示）实现：

1. 设置页「同步」区：云同步开关（默认关闭）、令牌输入（掩码、仅存本地 settings 表）、上次同步时间、立即同步按钮（同步中 loading、失败显示错误 + 重试）。
2. 状态栏同步指示：`● 已同步 / ⟳ 同步中 / ⚠ 失败 n 次`（色值按 style.md：accent / text-secondary / danger）；点击进入设置页同步区；云同步关闭时不显示。
3. 冲突提示：本地版本已备份时，状态栏或设置页给出可读提示（备份目录路径）。

## Context

- docs/app/ui-settings.md（§同步区）
- docs/app/ui-shell.md（§Interactions 同步状态点）
- docs/app/style.md（§9 状态色）
- docs/app/sync.md（§5 输家保护）

## Path

- `lib/ui/settings_view.dart`, `lib/ui/status_bar.dart`
- `test/ui/sync_test.dart`

## Verification

- widget test：开关切换状态机；令牌输入保存不回显明文；立即同步触发 push/pull 并更新「上次同步」；失败态显示错误；状态栏指示随 SyncState 变化。
- `flutter analyze` 无错误。
