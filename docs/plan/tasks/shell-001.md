# Task shell-001 — 主界面壳

```yaml
id: shell-001
scope: lib/ui + lib/state
status: done
depends-on: [store-001]
```

## Objective

1. `state/library_controller.dart`（ChangeNotifier）：目录树、当前文档、未保存缓冲、今日增量；`switchDocument()` 先保存旧文档；`restore()` 按 `last-open.json` 恢复。
2. `state/settings_controller.dart`：设置读写、主题/字体变更通知。
3. `ui/shell.dart`：按 docs/app/ui-shell.md 实现壳布局；宽度 ≥800 桌面形态（固定侧边栏），<800 Android 形态（Drawer）；状态栏容器（今日进度 + 本文字数，数据接 controller，本文字数先显示 0，编辑逻辑归 edit-003）。
4. 主题接线：MaterialApp 读 `settings_controller`，深色/浅色/跟随系统；色板用纸色/墨色系（浅色 #FAF6EF 底，深色 #1E1D1A 底，强调色 黛绿 #3E6B5B），Material 3 `ColorScheme.fromSeed`。

## Context

- docs/app/ui-shell.md（整体）
- docs/app/README.md（§5、§6、§8）
- docs/plan/analysis/requirements.md（F5.1、F6）

## Path

- `lib/state/*.dart`, `lib/ui/shell.dart`, `lib/main.dart`, `lib/app.dart`
- `test/ui/shell_test.dart`

## Verification

- widget test：壳在桌面尺寸渲染侧边栏、在手机尺寸渲染 Drawer；空库显示空态；状态栏渲染今日进度。
- `flutter analyze` 无错误；`flutter test` 通过。
