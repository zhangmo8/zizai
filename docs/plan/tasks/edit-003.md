# Task edit-003 — 编辑器与沉浸模式

```yaml
id: edit-003
scope: lib/ui
status: pending
depends-on: [side-002]
```

## Objective

按 docs/app/ui-editor.md 实现所见即所得编辑器：

1. 内容区：`flutter_quill` 的 `QuillEditor`，最大行宽 720px 居中，空文档占位文案（非插入文本）。
2. 上下文工具栏：选中文本时在选区上方浮现（标题 H1–H3、加粗/斜体/下划线/删除线、无序/有序列表、引用、行内代码、代码块）；点击空白/`Esc` 收起；沉浸模式不显示。
3. 自动保存：Delta 变更防抖 1s；失焦/切换/退出立即保存；保存失败状态栏错误条 + 重试，缓冲保留。
4. 字数：`document.toPlainText()` → `core/word_count`；状态栏今日进度接 controller 增量；`Ctrl/Cmd+S` 立即保存并闪「已保存」。
5. 沉浸模式：`Ctrl/Cmd+Shift+F` 进入、`Esc` 退出；进出不打断光标与滚动；Android 下滑/按钮兜底。
6. 崩溃恢复：启动时缓冲与库不一致 → 恢复确认条。

## Context

- docs/app/ui-editor.md（整体）
- docs/app/README.md（§6 状态流、增量规则）
- docs/plan/analysis/requirements.md（F2、F3、F4、NFR）

## Path

- `lib/ui/editor.dart`, `lib/ui/status_bar.dart`, `lib/ui/focus_view.dart`, `lib/util/debounce.dart`
- `test/ui/editor_test.dart`

## Verification

- widget test：输入→防抖保存→字数正确；切文档触发保存；保存失败重试；FocusMode 进出不打断。
- `flutter analyze` 无错误；`flutter test` 通过。
