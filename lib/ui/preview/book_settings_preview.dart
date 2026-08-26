/// 「写作设置」对话框预览（静态重建：写作目标 / 段落缩进 / 分卷）。
///
/// 查看：`flutter widget-preview start`
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../app.dart';

@Preview(group: '页面', name: '写作设置', size: Size(460, 560))
Widget bookSettingsPreview() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: const Scaffold(
      backgroundColor: Color(0xFFF2F1EF),
      body: Center(child: _StaticBookSettings()),
    ),
  );
}

class _StaticBookSettings extends StatelessWidget {
  const _StaticBookSettings();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 460,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE6E4DF)),
        boxShadow: const [
          BoxShadow(color: Color(0x1A000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
            child: Row(
              children: const [
                Expanded(
                  child: Text(
                    '写作设置 · 我的小说',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF37352F)),
                  ),
                ),
                _CloseButton(),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE6E4DF)),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: const [
                  _Group(
                    label: '写作目标',
                    children: [
                      _Row(
                        label: '启用今日目标',
                        control: _SwitchPreview(on: true),
                        description: '关闭后不在状态栏和沉浸模式显示',
                      ),
                      _Row(
                        label: '每日目标字数',
                        control: _FieldPreview(text: '2000'),
                        description: '只计入这本书今天新增的文字',
                      ),
                    ],
                  ),
                  _Group(
                    label: '段落缩进',
                    children: [
                      _Row(
                        label: '行首自动缩进',
                        control: _SwitchPreview(on: true),
                        description: '新段落行首自动空两个全角空格',
                      ),
                    ],
                  ),
                  _Group(
                    label: '分卷',
                    children: [
                      _Row(
                        label: '启用分卷',
                        control: _SwitchPreview(on: true),
                        description: '开启后按卷在目录里组织章节',
                      ),
                      _Row(
                        label: '分卷方式',
                        control: _SelectPreview(text: '自动分卷'),
                        description: '自动 = 每 N 章一卷；手动 = 侧边栏自建卷并归章',
                      ),
                      _Row(
                        label: '每卷章数',
                        control: _FieldPreview(text: '3'),
                        description: '第 1~3 章为第一卷，之后每 3 章一卷',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 28,
      height: 28,
      child: Icon(Icons.close, size: 18, color: Color(0xFF787774)),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF9B9A97)),
          ),
        ),
        const Divider(height: 1, color: Color(0xFFE6E4DF)),
        ...children,
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.control, this.description});

  final String label;
  final Widget control;
  final String? description;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF37352F))),
              ),
              control,
            ],
          ),
          if (description != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                description!,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9B9A97)),
              ),
            ),
        ],
      ),
    );
  }
}

class _SwitchPreview extends StatelessWidget {
  const _SwitchPreview({required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 18,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: on ? const Color(0xFF2383E2) : const Color(0x38787374),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Align(
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 14,
          height: 14,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _SelectPreview extends StatelessWidget {
  const _SelectPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 96),
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE6E4DF)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: const TextStyle(fontSize: 13, color: Color(0xFF37352F))),
          const SizedBox(width: 5),
          const Icon(Icons.expand_more, size: 14, color: Color(0xFF9B9A97)),
        ],
      ),
    );
  }
}

class _FieldPreview extends StatelessWidget {
  const _FieldPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 140,
      height: 32,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0x0A37352F),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: const TextStyle(fontSize: 13, color: Color(0xFF37352F))),
    );
  }
}
