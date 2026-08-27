/// 章节字数分布对话框（节奏图）：目录正序逐章一行，条形长度 ∝ 本章字数，
/// 点击跳转该章；头部汇总全书章数 / 总字数 / 平均每章。
///
/// 设计依据：docs/app/ui-sidebar.md §章节字数分布、design.md（Notion token、
/// 6px 浮层卡片、hover 反馈）。数据取 controller 树缓存（words 为保存快照），
/// 经 ListenableBuilder 跟随库变化自动重建（如打开期间自动保存落盘）。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;
import '../core/word_distribution.dart';
import '../state/library_controller.dart';

/// 打开字数分布对话框。[onOpen] 收到被点中的章节 id（对话框已关闭后调用）。
Future<void> showWordDistributionDialog(
  BuildContext context, {
  required LibraryController library,
  required void Function(String documentId) onOpen,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      alignment: const Alignment(0, -0.35),
      child: _WordDistributionPanel(library: library, onOpen: onOpen),
    ),
  );
}

class _WordDistributionPanel extends StatelessWidget {
  const _WordDistributionPanel({required this.library, required this.onOpen});

  final LibraryController library;
  final void Function(String documentId) onOpen;

  @override
  Widget build(BuildContext context) {
    final appColors = appColorsOf(context);
    final size = MediaQuery.sizeOf(context);
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final nb = library.currentNotebook;
        final dist = buildWordDistribution(
          nb == null ? const [] : library.documentsOf(nb.id),
        );
        final currentId = library.currentDocument?.id;
        return SizedBox(
          width: (size.width - 48).clamp(360.0, 560.0),
          height: (size.height - 96).clamp(240.0, 560.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      '章节字数分布',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      dist.count == 0
                          ? '还没有章节'
                          : '${dist.count} 章 · 共 ${_thousands(dist.totalWords)} 字'
                                ' · 均 ${_thousands(dist.averageWords)} 字/章',
                      style: TextStyle(
                        fontSize: 12,
                        color: appColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: Theme.of(context).dividerColor),
              Expanded(
                child: dist.count == 0
                    ? Center(
                        child: Text(
                          '新建章节后，这里会展示全书的节奏',
                          style: TextStyle(
                            fontSize: 12,
                            color: appColors.textTertiary,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: dist.chapters.length,
                        itemBuilder: (context, i) {
                          final chapter = dist.chapters[i];
                          return _WordRow(
                            key: ValueKey(chapter.id),
                            chapter: chapter,
                            maxWords: dist.maxWords,
                            active: chapter.id == currentId,
                            onTap: () => onOpen(chapter.id),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 单章一行：底色块宽度 ∝ 字数（基准 = 最长章），叠章名 + 字数。
class _WordRow extends StatefulWidget {
  const _WordRow({
    super.key,
    required this.chapter,
    required this.maxWords,
    required this.active,
    required this.onTap,
  });

  final ChapterWords chapter;

  /// 条形长度基准（最长章）；0 = 不画条形。
  final int maxWords;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_WordRow> createState() => _WordRowState();
}

class _WordRowState extends State<_WordRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final factor = widget.maxWords > 0
        ? (widget.chapter.words / widget.maxWords).clamp(0.0, 1.0)
        : 0.0;
    // 条形用 accent 极低透明度铺底，hover 加深；不做圆角（行高亮语义，
    // 且不引入 design.md 三档之外的圆角）。
    final fillOpacity = _hover ? 0.18 : 0.09;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onTap,
        child: SizedBox(
          height: 34,
          child: Stack(
            children: [
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: factor,
                  child: ColoredBox(
                    color: colors.primary.withValues(alpha: fillOpacity),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.chapter.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: widget.active
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: widget.active
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _thousands(widget.chapter.words),
                      style: TextStyle(
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: widget.active
                            ? colors.primary
                            : appColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 千分位（字数为非负整数）。
String _thousands(int n) {
  final digits = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    buf.write(digits[i]);
    final remaining = digits.length - i - 1;
    if (remaining > 0 && remaining % 3 == 0) buf.write(',');
  }
  return buf.toString();
}
