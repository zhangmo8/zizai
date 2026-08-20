/// 章节备注面板：编辑区右侧的可折叠侧栏，记录不进正文导出的章节备注。
///
/// 设计依据：用户需求「章节备注」——本章目的、出场人物、伏笔、待修改事项、
/// 情节时间和地点。design.md（Notion token、圆角 4px、textarea 无边框）。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;

/// 章节备注面板。
class NotesPanel extends StatefulWidget {
  const NotesPanel({
    super.key,
    required this.notes,
    required this.onChanged,
  });

  static const double width = 240;

  /// 当前备注文本。
  final String notes;

  /// 备注变更回调（防抖由调用方处理）。
  final void Function(String notes) onChanged;

  @override
  State<NotesPanel> createState() => NotesPanelState();
}

class NotesPanelState extends State<NotesPanel> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.notes);
  }

  @override
  void didUpdateWidget(covariant NotesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部更新（如切换文档）时同步 controller，但不覆盖正在输入的内容。
    if (oldWidget.notes != widget.notes && _controller.text != widget.notes) {
      _controller.text = widget.notes;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return SizedBox(
      width: NotesPanel.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                Icon(
                  Icons.sticky_note_2_outlined,
                  size: 14,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  '章节备注',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.outline),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: colors.onSurface,
                ),
                cursorColor: colors.primary,
                cursorWidth: 2,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: appColors.callout,
                  hintText: '本章目的、出场人物、伏笔、待修改事项…',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: appColors.textTertiary,
                  ),
                  contentPadding: const EdgeInsets.all(8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(color: colors.primary),
                  ),
                ),
                onChanged: widget.onChanged,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Text(
              '备注不会出现在导出的正文中',
              style: TextStyle(
                fontSize: 11,
                color: appColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
