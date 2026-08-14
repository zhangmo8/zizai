/// 大纲面板：单文档标题列表（H1–H3 缩进），点击跳转 + 当前标题高亮。
///
/// 设计依据：docs/app/ui-editor.md §大纲面板、design.md（Notion token、
/// 圆角 4/6/8px、hover 反馈）。常驻态与右缘悬浮浮层共用本组件。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;
import '../core/outline.dart';

class OutlinePanel extends StatelessWidget {
  const OutlinePanel({
    super.key,
    required this.entries,
    required this.activeIndex,
    required this.onJump,
  });

  static const double width = 220;

  final List<OutlineEntry> entries;

  /// 跟随高亮的条目下标（-1 = 无）。
  final int activeIndex;

  final void Function(OutlineEntry entry) onJump;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    if (entries.isEmpty) {
      return SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: Text(
            '使用 H1–H3 标题，这里会生成大纲',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: appColors.textTertiary,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: width,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final entry = entries[i];
          final active = i == activeIndex;
          return _OutlineRow(
            key: ValueKey('outline-$i'),
            text: entry.text.isEmpty ? '（无标题）' : entry.text,
            level: entry.level,
            active: active,
            accent: colors.primary,
            onTap: () => onJump(entry),
          );
        },
      ),
    );
  }
}

class _OutlineRow extends StatefulWidget {
  const _OutlineRow({
    super.key,
    required this.text,
    required this.level,
    required this.active,
    required this.accent,
    required this.onTap,
  });

  final String text;
  final int level;
  final bool active;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_OutlineRow> createState() => _OutlineRowState();
}

class _OutlineRowState extends State<_OutlineRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: widget.onTap,
        child: Container(
          padding: EdgeInsets.only(
            // H1–H3 缩进阶梯。
            left: 8.0 + (widget.level - 1) * 12,
            right: 8,
            top: 5,
            bottom: 5,
          ),
          decoration: BoxDecoration(
            color: _hover ? appColors.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
              color: widget.active ? widget.accent : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
