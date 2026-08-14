# Task find-001 — 单章节查找/替换

```yaml
id: find-001
scope: lib/ui + lib/core
status: done
depends-on: [edit-003]
```

## Objective

按 docs/app/ui-editor.md（§查找与替换）实现：

1. `core/find.dart`：纯函数 —— `findMatches`（大小写不敏感、不重叠）+
   `nextMatchIndex`（光标后最近匹配，回绕）。
2. 编辑区右上角查找条浮层（`ui/find_bar.dart`）：
   - 顶栏搜索 icon / `Ctrl/Cmd+F` 打开，选区（单行 ≤64 字符）带入初始查询；
   - 计数「当前/总数」、无结果态；`Enter`/`Shift+Enter` 与 ↑↓ 按钮循环切换；
   - 折叠替换行：替换当前 + 全部替换（toast 数量）；`Esc` 关闭并交还焦点。
3. 当前匹配以选区高亮并滚动至视口上 1/3；编辑实时重算计数；切换文档自动关闭。

## Path

- `lib/core/find.dart`、`lib/ui/find_bar.dart`、`lib/ui/editor.dart`（快捷键 + 接线）
- `test/core/find_test.dart`、`test/ui/find_bar_test.dart`

## Verification

- 单测：匹配偏移（含中文）、大小写、回绕、空查询。
- widget test：输入回调、Enter 下一个、替换/全部替换、无结果置灰。
- `flutter analyze` / `flutter test` 通过。
