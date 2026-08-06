# Task side-002 — 文档树侧边栏

```yaml
id: side-002
scope: lib/ui
status: done
depends-on: [shell-001]
```

## Objective

按 docs/app/ui-sidebar.md 实现侧边栏：

1. 笔记本/章节树渲染（展开折叠、当前文档高亮）。
2. 文档 CRUD 交互：行内重命名（Enter 确认 / Esc 取消）、删除确认条（非模态，5s 自动关）、新建笔记本、新建章节（默认名后行内重命名）。
3. 空态引导；文件名冲突/非法名错误态。
4. Android Drawer 与桌面常驻栏共用同一 widget 树（由 shell 决定宿主容器）。

## Context

- docs/app/ui-sidebar.md（整体）
- docs/app/ui-shell.md（Region Layout、State Variants）
- docs/plan/analysis/requirements.md（F1）

## Path

- `lib/ui/sidebar.dart`
- `test/ui/sidebar_test.dart`

## Verification

- widget test：新建/重命名/删除文档流程；冲突名错误态；删除确认条出现与超时关闭。
- `flutter analyze` 无错误；`flutter test` 通过。
