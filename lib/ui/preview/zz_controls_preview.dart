/// Zz 控件预览：真实渲染 Zz 按钮 / 图标按钮 / 开关 / 滑块 / 下拉 / 输入框 /
/// Toast / 确认弹窗 / 命名对话框。
///
/// 查看：`flutter widget-preview start`
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../app.dart';
import '../zz.dart';

/// 预览框架：浅色主题 + 内边距画布。
Widget _frame(Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    home: Scaffold(
      backgroundColor: Colors.white,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  );
}

Widget _label(String text) => Padding(
  padding: const EdgeInsets.only(bottom: 6),
  child: Text(
    text,
    style: const TextStyle(fontSize: 12, color: Color(0xFF9B9A97)),
  ),
);

Widget _gap() => const SizedBox(height: 16);

@Preview(group: 'Zz 控件', name: '按钮', size: Size(560, 200))
Widget zzButtonsPreview() {
  return _frame(Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _label('主 / 次 / 文字 / 加载 / 禁用'),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ZzButton.primary(label: '主按钮', onPressed: () {}),
          ZzButton.secondary(label: '次按钮', onPressed: () {}),
          ZzButton.link(label: '文字按钮', onPressed: () {}),
          ZzButton.primary(label: '加载中', onPressed: () {}, busy: true),
          ZzButton.primary(label: '禁用', onPressed: null),
        ],
      ),
      _gap(),
      _label('图标按钮（hover/pressed 反馈 + tooltip）'),
      Row(
        children: [
          ZzIconButton(tooltip: '新建', icon: Icons.add, onPressed: () {}),
          ZzIconButton(tooltip: '设置', icon: Icons.settings_outlined, onPressed: () {}),
          ZzIconButton(tooltip: '搜索', icon: Icons.search, onPressed: () {}),
          ZzIconButton(tooltip: '返回', icon: Icons.arrow_back, onPressed: () {}),
          ZzIconButton(tooltip: '关闭', icon: Icons.close, onPressed: () {}),
        ],
      ),
    ],
  ));
}

@Preview(group: 'Zz 控件', name: '开关 / 滑块', size: Size(560, 220))
Widget zzTogglePreview() {
  return _frame(const _ToggleShowcase());
}

class _ToggleShowcase extends StatefulWidget {
  const _ToggleShowcase();

  @override
  State<_ToggleShowcase> createState() => _ToggleShowcaseState();
}

class _ToggleShowcaseState extends State<_ToggleShowcase> {
  bool _on = true;
  double _slider = 20;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('开关（off 灰 / on accent，120ms 位移动画）'),
        Row(
          children: [
            const SizedBox(width: 130, child: Text('启用今日目标', style: TextStyle(fontSize: 13))),
            ZzSwitch(value: _on, onChanged: (v) => setState(() => _on = v)),
            const SizedBox(width: 32),
            const SizedBox(width: 130, child: Text('行首自动缩进', style: TextStyle(fontSize: 13))),
            ZzSwitch(value: !_on, onChanged: (v) => setState(() => _on = !v)),
          ],
        ),
        _gap(),
        _label('滑块（4px 细轨道 + 12px 圆点，accent 填充）'),
        Row(
          children: [
            const SizedBox(width: 130, child: Text('字号', style: TextStyle(fontSize: 13))),
            SizedBox(
              width: 200,
              child: ZzSlider(
                min: 12,
                max: 28,
                value: _slider,
                onChanged: (v) => setState(() => _slider = v),
              ),
            ),
            const SizedBox(width: 12),
            Text('${_slider.round()}', style: const TextStyle(fontSize: 13)),
          ],
        ),
      ],
    );
  }
}

@Preview(group: 'Zz 控件', name: '下拉选择 / 输入框', size: Size(560, 240))
Widget zzInputPreview() {
  return _frame(const _InputShowcase());
}

class _InputShowcase extends StatefulWidget {
  const _InputShowcase();

  @override
  State<_InputShowcase> createState() => _InputShowcaseState();
}

class _InputShowcaseState extends State<_InputShowcase> {
  String _lang = '简体中文';
  final TextEditingController _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('下拉选择（锚定菜单，当前项 ✓）'),
        Row(
          children: [
            const SizedBox(width: 130, child: Text('界面语言', style: TextStyle(fontSize: 13))),
            ZzSelect<String>(
              value: _lang,
              display: _lang,
              options: const [
                (label: '简体中文', value: '简体中文'),
                (label: '繁體中文', value: '繁體中文'),
                (label: 'English', value: 'English'),
              ],
              onChanged: (v) => setState(() => _lang = v),
            ),
          ],
        ),
        _gap(),
        _label('输入框（bg-hover 底、无边框、focus accent 内描边）'),
        Row(
          children: [
            const SizedBox(width: 130, child: Text('笔记本名称', style: TextStyle(fontSize: 13))),
            SizedBox(
              width: 260,
              child: ZzTextField(controller: _name, hint: '例如：我的小说'),
            ),
          ],
        ),
        _gap(),
        Row(
          children: [
            const SizedBox(width: 130, child: Text('数字输入', style: TextStyle(fontSize: 13))),
            SizedBox(
              width: 140,
              child: ZzTextField(
                controller: TextEditingController(text: '2000'),
                hint: '100–50000',
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

@Preview(group: 'Zz 控件', name: 'Toast / 确认 / 命名对话框', size: Size(560, 200))
Widget zzFeedbackPreview() {
  return _frame(const _FeedbackShowcase());
}

class _FeedbackShowcase extends StatelessWidget {
  const _FeedbackShowcase();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('交互反馈（异步结果 / 危险操作 / 命名）'),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            ZzButton.secondary(
              label: '弹出 Toast',
              onPressed: () => showZzToast(context, '已保存'),
            ),
            ZzButton.secondary(
              label: '危险确认',
              onPressed: () => zzConfirm(
                context,
                title: '删除笔记本？',
                message: '将删除该笔记本及其全部章节，此操作不可恢复。',
                confirmLabel: '删除',
                danger: true,
              ),
            ),
            ZzButton.secondary(
              label: '命名对话框',
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _NameDialogPreview(),
              ),
            ),
          ],
        ),
        _gap(),
        Text(
          '· 操作结果一律 toast（2.5s 自动消失）\n'
          '· 危险操作用 zzConfirm 确认，确认按钮 danger 红\n'
          '· 命名用 6px 圆角小弹层，ZzTextField + ZzButton',
          style: const TextStyle(
            fontSize: 12,
            height: 1.6,
            color: Color(0xFF9B9A97),
          ),
        ),
      ],
    );
  }
}

/// 命名对话框静态预览（与 LibraryHome 的 _NameDialog 视觉一致）。
class _NameDialogPreview extends StatefulWidget {
  const _NameDialogPreview();

  @override
  State<_NameDialogPreview> createState() => _NameDialogPreviewState();
}

class _NameDialogPreviewState extends State<_NameDialogPreview> {
  final TextEditingController _controller = TextEditingController(text: '新笔记本');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: appColorsOf(context).surfaceRaised,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: colors.outline),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1A000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '重命名笔记本',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            ZzTextField(
              controller: _controller,
              hint: '笔记本名称',
              autofocus: true,
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ZzButton.link(
                    label: '取消',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 4),
                  ZzButton.primary(
                    label: '确定',
                    onPressed: () => Navigator.of(context).pop(),
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
