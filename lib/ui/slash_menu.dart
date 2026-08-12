/// 斜杠命令菜单：输入「/」在光标处浮现的块类型菜单（Notion-like）。
///
/// 本文件只负责命令定义 + 面板渲染；触发/定位/键盘导航由 editor.dart
/// 的 overlay 逻辑驱动，保持面板为纯展示组件。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;

/// 一条斜杠命令：id 由编辑器 switch 消费。
class SlashCommand {
  const SlashCommand({
    required this.id,
    required this.label,
    required this.hint,
    required this.icon,
    required this.keywords,
  });

  final String id;
  final String label;

  /// 菜单右侧的浅色提示（markdown 等价语法）。
  final String hint;
  final IconData icon;

  /// 过滤关键词（英文/拼音助记，全部小写）。
  final List<String> keywords;
}

const List<SlashCommand> kSlashCommands = [
  SlashCommand(
    id: 'text',
    label: '正文',
    hint: '',
    icon: Icons.notes,
    keywords: ['text', 'p', 'plain', 'zhengwen', '正文'],
  ),
  SlashCommand(
    id: 'h1',
    label: '标题 1',
    hint: '#',
    icon: Icons.title,
    keywords: ['h1', 'head', 'title', 'biaoti', '标题'],
  ),
  SlashCommand(
    id: 'h2',
    label: '标题 2',
    hint: '##',
    icon: Icons.title,
    keywords: ['h2', 'head', 'biaoti', '标题'],
  ),
  SlashCommand(
    id: 'h3',
    label: '标题 3',
    hint: '###',
    icon: Icons.title,
    keywords: ['h3', 'head', 'biaoti', '标题'],
  ),
  SlashCommand(
    id: 'bullet',
    label: '无序列表',
    hint: '-',
    icon: Icons.format_list_bulleted,
    keywords: ['ul', 'bullet', 'list', 'liebiao', '列表'],
  ),
  SlashCommand(
    id: 'ordered',
    label: '有序列表',
    hint: '1.',
    icon: Icons.format_list_numbered,
    keywords: ['ol', 'ordered', 'number', 'list', 'liebiao', '列表'],
  ),
  SlashCommand(
    id: 'todo',
    label: '待办清单',
    hint: '[]',
    icon: Icons.check_box_outlined,
    keywords: ['todo', 'task', 'check', 'daiban', '待办'],
  ),
  SlashCommand(
    id: 'quote',
    label: '引用',
    hint: '>',
    icon: Icons.format_quote,
    keywords: ['quote', 'blockquote', 'yinyong', '引用'],
  ),
  SlashCommand(
    id: 'code',
    label: '代码块',
    hint: '```',
    icon: Icons.data_object,
    keywords: ['code', 'codeblock', 'daima', '代码'],
  ),
];

/// 过滤：空串返回全部；否则 label 包含 / 关键词前缀命中。
List<SlashCommand> filterSlashCommands(String query) {
  final trimmed = query.trim().toLowerCase();
  if (trimmed.isEmpty) return kSlashCommands;
  return [
    for (final cmd in kSlashCommands)
      if (cmd.label.contains(trimmed) ||
          cmd.keywords.any((k) => k.startsWith(trimmed)))
        cmd,
  ];
}

/// 菜单面板：纯展示，选中项高亮，hover/点击回调给编辑器。
class SlashMenuPanel extends StatelessWidget {
  const SlashMenuPanel({
    super.key,
    required this.commands,
    required this.selectedIndex,
    required this.onSelect,
    required this.onHover,
  });

  final List<SlashCommand> commands;
  final int selectedIndex;
  final ValueChanged<SlashCommand> onSelect;
  final ValueChanged<int> onHover;

  static const double width = 240;
  static const double itemHeight = 36;
  static const double maxHeight = 324;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        width: width,
        constraints: const BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: appColors.surfaceRaised,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: colors.outline),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 5),
            itemCount: commands.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                  child: Text(
                    '转换为',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: appColors.textTertiary,
                    ),
                  ),
                );
              }
              final index = i - 1;
              final cmd = commands[index];
              final selected = index == selectedIndex;
              return _SlashMenuItem(
                command: cmd,
                selected: selected,
                onTap: () => onSelect(cmd),
                onHover: () => onHover(index),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SlashMenuItem extends StatelessWidget {
  const _SlashMenuItem({
    required this.command,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });

  final SlashCommand command;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return MouseRegion(
      onEnter: (_) => onHover(),
      child: GestureDetector(
        // Quill 编辑器持有焦点；用 onTapDown 抢在焦点系统之前应用命令。
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => onTap(),
        child: Container(
          height: SlashMenuPanel.itemHeight,
          margin: const EdgeInsets.symmetric(horizontal: 5),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? appColors.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colors.outline),
                ),
                child: Icon(
                  command.icon,
                  size: 14,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  command.label,
                  style: TextStyle(fontSize: 13, color: colors.onSurface),
                ),
              ),
              if (command.hint.isNotEmpty)
                Text(
                  command.hint,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'Menlo',
                    color: appColors.textTertiary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
