/// 单书侧边栏预览（静态重建：分卷开启、当前章节高亮）。
///
/// 查看：`flutter widget-preview start`
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../app.dart';

@Preview(name: 'Sidebar', group: '页面', size: Size(280, 620))
Widget sidebarPreview() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: const _StaticSidebar(),
  );
}

class _StaticSidebar extends StatelessWidget {
  const _StaticSidebar();

  @override
  Widget build(BuildContext context) {
    final appColors = appColorsOf(context);
    return ColoredBox(
      color: appColors.sidebar,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶栏：返回 + 书名 + 搜索 + 本书设置
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 8, 6),
              child: Row(
                children: [
                  _PreviewIconButton(tooltip: '返回笔记本管理', icon: Icons.arrow_back),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text(
                      '我的小说',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF37352F),
                      ),
                    ),
                  ),
                  _PreviewIconButton(tooltip: '全书搜索', icon: Icons.search),
                  _PreviewIconButton(tooltip: '这本书的设置', icon: Icons.settings_outlined),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFE6E4DF)),
            // 分卷标题 + 章节
            const _PreviewVolume(number: '第一卷'),
            const _PreviewDocument(title: '第 1 章', selected: true),
            const _PreviewDocument(title: '第 2 章'),
            const _PreviewDocument(title: '第 3 章'),
            const _PreviewVolume(number: '第二卷'),
            const _PreviewDocument(title: '第 4 章'),
            const _PreviewDocument(title: '第 5 章'),
            // 新建章节
            const Padding(
              padding: EdgeInsets.only(left: 34, top: 4, bottom: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '+ 新建章节',
                  style: TextStyle(fontSize: 12, color: Color(0xFF787774)),
                ),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _PreviewIconButton extends StatelessWidget {
  const _PreviewIconButton({required this.tooltip, required this.icon});

  final String tooltip;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () {},
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 18, color: const Color(0xFF787774)),
        ),
      ),
    );
  }
}

class _PreviewVolume extends StatelessWidget {
  const _PreviewVolume({required this.number});

  final String number;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      child: Text(
        number,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
          color: Color(0xFF9B9A97),
        ),
      ),
    );
  }
}

class _PreviewDocument extends StatelessWidget {
  const _PreviewDocument({required this.title, this.selected = false});

  final String title;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      padding: const EdgeInsets.only(left: 28, right: 6),
      decoration: BoxDecoration(
        color: selected ? const Color(0x0F37352F) : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Icon(
            Icons.description_outlined,
            size: 15,
            color: selected ? const Color(0xFF37352F) : const Color(0xFF787774),
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
                color: selected ? const Color(0xFF37352F) : const Color(0xFF787774),
              ),
            ),
          ),
          if (selected)
            const Icon(Icons.more_horiz, size: 16, color: Color(0xFF9B9A97)),
        ],
      ),
    );
  }
}
