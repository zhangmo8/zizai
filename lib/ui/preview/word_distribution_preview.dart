/// 章节字数分布对话框预览（静态重建：头部汇总 + 目录正序条形行）。
///
/// 查看：`flutter widget-preview start`
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../app.dart';

@Preview(name: '章节字数分布', group: '弹层', size: Size(620, 460))
Widget wordDistributionPreview() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: Scaffold(
      backgroundColor: const Color(0x5537352F),
      body: Center(child: _StaticWordDistDialog()),
    ),
  );
}

class _StaticWordDistDialog extends StatelessWidget {
  const _StaticWordDistDialog();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const rows = <(String, int)>[
      ('第 1 章 开端', 3200),
      ('第 2 章 林渊入门', 8400),
      ('第 3 章 比试', 1000),
      ('第 4 章 低谷', 0),
    ];
    const maxWords = 8400;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 560,
        height: 320,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    '章节字数分布',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF37352F),
                    ),
                  ),
                  Text(
                    '4 章 · 共 12,600 字 · 均 3,150 字/章',
                    style: TextStyle(fontSize: 12, color: Color(0xFF9B9A97)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFE6E4DF)),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  for (final (title, words) in rows)
                    _PreviewWordRow(
                      title: title,
                      words: words,
                      maxWords: maxWords,
                      active: title == '第 2 章 林渊入门',
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewWordRow extends StatelessWidget {
  const _PreviewWordRow({
    required this.title,
    required this.words,
    required this.maxWords,
    this.active = false,
  });

  final String title;
  final int words;
  final int maxWords;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final factor = maxWords > 0 ? (words / maxWords).clamp(0.0, 1.0) : 0.0;
    return SizedBox(
      height: 34,
      child: Stack(
        children: [
          Positioned.fill(
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: factor,
              child: ColoredBox(
                color: colors.primary.withValues(alpha: 0.09),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$words',
                  style: TextStyle(
                    fontSize: 12,
                    color: active ? colors.primary : const Color(0xFF9B9A97),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
