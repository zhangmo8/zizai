# Task outline-001 — 单文档大纲面板

```yaml
id: outline-001
scope: lib/ui + lib/core
status: pending
depends-on: [integ-005]
```

## Objective

按 docs/app/ui-editor.md（§大纲面板）实现：

1. `core/outline.dart`：纯函数 —— Delta → `List<OutlineEntry>{text, level(1-3), offset}`；
   挂编辑防抖管道增量刷新。
2. 右侧可折叠面板：
   - EditorHeader 最右侧 icon 切换，展开状态记忆（settings 表）；窄窗（<960px）强制收起；
   - 收起时右缘 8px 热区 hover → overlay 浮层滑出，离开即收；热区不拦截编辑区滚动；
   - 沉浸模式自动收起、热区保持可用，退出恢复原状态；
   - Android 仅 icon 切换，沉浸不提供。
3. 点击跳转（光标至标题行首、滚动至视口上 1/3）+ 滚动跟随高亮 + 空态引导文案。

## Context

- docs/app/ui-editor.md（§大纲面板、§FocusMode 细节）
- docs/app/style.md（§3 tokens；面板/浮层圆角 4/6/8px）

## Path

- `lib/core/outline.dart`、`lib/ui/outline_panel.dart`、`lib/ui/editor.dart`（header icon + 接线）
- `test/core/outline_test.dart`、`test/ui/outline_test.dart`

## Verification

- 单测：多级标题提取、无标题空列表、offset 正确（含格式混排）。
- widget test：icon 切换与状态记忆、点击跳转光标位置、空态文案、窄窗强制收起、
  沉浸模式下常驻面板不渲染。
- `flutter analyze` / `flutter test` 通过。
