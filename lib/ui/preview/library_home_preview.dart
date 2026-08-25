/// 笔记本管理页预览（静态重建：网格 / 列表 / 空态 / 视图切换）。
///
/// 查看：`flutter widget-preview start`
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../app.dart';

Widget _frame(Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: Scaffold(
      backgroundColor: Colors.white,
      body: child,
    ),
  );
}

/// 顶栏：标题 + 视图切换 + 新建 + 设置。
class _PreviewHeader extends StatelessWidget {
  const _PreviewHeader({this.listMode = false});

  final bool listMode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 14, 10),
      child: Row(
        children: [
          const Text(
            '笔记本',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF37352F)),
          ),
          const Spacer(),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE6E4DF)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ToggleCell(icon: Icons.grid_view, tooltip: '网格视图', active: !listMode),
                _ToggleCell(icon: Icons.view_list, tooltip: '列表视图', active: listMode),
              ],
            ),
          ),
          const SizedBox(width: 4),
          const _HeaderIcon(tooltip: '新建笔记本', icon: Icons.add),
          const _HeaderIcon(tooltip: '设置', icon: Icons.settings_outlined),
        ],
      ),
    );
  }
}

class _ToggleCell extends StatelessWidget {
  const _ToggleCell({required this.icon, required this.tooltip, required this.active});

  final IconData icon;
  final String tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () {},
        child: Container(
          width: 32,
          height: 26,
          decoration: BoxDecoration(
            color: active ? const Color(0x0F37352F) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            size: 16,
            color: active ? const Color(0xFF787774) : const Color(0xFF9B9A97),
          ),
        ),
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({required this.tooltip, required this.icon});

  final String tooltip;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () {},
        child: const SizedBox(
          width: 28,
          height: 28,
          child: Icon(Icons.add, size: 18, color: Color(0xFF787774)),
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.name, required this.meta});

  final String name;
  final String meta;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE6E4DF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF37352F)),
          ),
          const Spacer(),
          Text(meta, style: const TextStyle(fontSize: 12, color: Color(0xFF9B9A97))),
        ],
      ),
    );
  }
}

@Preview(group: '笔记本管理页', name: '网格视图', size: Size(720, 360))
Widget libraryHomeGridPreview() {
  return _frame(const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _PreviewHeader(),
      Divider(height: 1, color: Color(0xFFE6E4DF)),
      Expanded(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _PreviewCard(name: '我的小说', meta: '6 章 · 1920 字')),
                    SizedBox(width: 14),
                    Expanded(child: _PreviewCard(name: '随笔集', meta: '1 章 · 800 字')),
                    SizedBox(width: 14),
                    Expanded(child: _PreviewCard(name: '灵感碎片', meta: '0 章 · 0 字')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  ));
}

@Preview(group: '笔记本管理页', name: '列表视图', size: Size(720, 320))
Widget libraryHomeListPreview() {
  return _frame(const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _PreviewHeader(listMode: true),
      Divider(height: 1, color: Color(0xFFE6E4DF)),
      Expanded(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PreviewRow(name: '我的小说', meta: '6 章 · 1920 字'),
              Divider(height: 1, color: Color(0xFFE6E4DF)),
              _PreviewRow(name: '随笔集', meta: '1 章 · 800 字'),
              Divider(height: 1, color: Color(0xFFE6E4DF)),
              _PreviewRow(name: '灵感碎片', meta: '0 章 · 0 字'),
            ],
          ),
        ),
      ),
    ],
  ));
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.name, required this.meta});

  final String name;
  final String meta;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF37352F)),
            ),
          ),
          Text(meta, style: const TextStyle(fontSize: 12, color: Color(0xFF9B9A97))),
          const SizedBox(width: 8),
          const Icon(Icons.more_horiz, size: 18, color: Color(0xFF787774)),
        ],
      ),
    );
  }
}

@Preview(group: '笔记本管理页', name: '空态', size: Size(480, 320))
Widget libraryHomeEmptyPreview() {
  return _frame(const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _PreviewHeader(),
      Divider(height: 1, color: Color(0xFFE6E4DF)),
      Expanded(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined, size: 40, color: Color(0xFF9B9A97)),
              SizedBox(height: 10),
              Text('还没有笔记本', style: TextStyle(fontSize: 15, color: Color(0xFF37352F))),
              SizedBox(height: 4),
              Text('新建一本开始写作', style: TextStyle(fontSize: 13, color: Color(0xFF9B9A97))),
            ],
          ),
        ),
      ),
    ],
  ));
}
