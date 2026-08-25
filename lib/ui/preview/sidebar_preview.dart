import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../app.dart';

@Preview(name: 'Sidebar', group: 'Zizai', size: Size(280, 620))
Widget sidebarPreview() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark(),
    home: const _StaticSidebar(),
  );
}

class _StaticSidebar extends StatelessWidget {
  const _StaticSidebar();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return ColoredBox(
      color: appColors.sidebar,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.asset(
                      'assets/logo.png',
                      width: 32,
                      height: 32,
                      fit: BoxFit.cover,
                      semanticLabel: '字在',
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () {},
                    tooltip: '全书搜索',
                    icon: Icon(Icons.search, color: colors.onSurfaceVariant),
                  ),
                  IconButton(
                    onPressed: () {},
                    tooltip: '新建笔记本',
                    icon: Icon(Icons.add, color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const _PreviewNotebook(
              name: '我的写作',
              count: '3章',
              documents: ['序章：在字里相遇', '第一章：开始写作', '第二章：保持诚实'],
              selectedIndex: 1,
            ),
            const SizedBox(height: 4),
            const _PreviewNotebook(
              name: '灵感收集',
              count: '2章',
              documents: ['关于生活的片段', '还没想好标题'],
            ),
            const Spacer(),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.outline)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      Icon(
                        Icons.settings_outlined,
                        size: 17,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 9),
                      Text(
                        '设置',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        Icons.chevron_right,
                        size: 14,
                        color: appColors.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewNotebook extends StatelessWidget {
  const _PreviewNotebook({
    required this.name,
    required this.count,
    required this.documents,
    this.selectedIndex,
  });

  final String name;
  final String count;
  final List<String> documents;
  final int? selectedIndex;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: SizedBox(
            height: 30,
            child: Row(
              children: [
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                ),
                Text(
                  count,
                  style: TextStyle(fontSize: 11, color: appColors.textTertiary),
                ),
                const SizedBox(width: 4),
                Icon(Icons.more_horiz, size: 16, color: appColors.textTertiary),
              ],
            ),
          ),
        ),
        for (var i = 0; i < documents.length; i++)
          _PreviewDocument(title: documents[i], selected: i == selectedIndex),
        Padding(
          padding: const EdgeInsets.only(left: 34, top: 2, bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '+ 新建章节',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewDocument extends StatelessWidget {
  const _PreviewDocument({required this.title, required this.selected});

  final String title;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Container(
      height: 30,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      padding: const EdgeInsets.only(left: 28, right: 6),
      decoration: BoxDecoration(
        color: selected ? appColors.rowSelected : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(
            Icons.description_outlined,
            size: 15,
            color: selected ? colors.onSurface : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? colors.onSurface : colors.onSurfaceVariant,
              ),
            ),
          ),
          if (selected)
            Icon(Icons.more_horiz, size: 16, color: appColors.textTertiary),
        ],
      ),
    );
  }
}
