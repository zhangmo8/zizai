import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/outline.dart';
import 'package:zi_zai/ui/outline_panel.dart';

void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: Align(child: child)));

  const entries = [
    OutlineEntry(text: '第一章', level: 1, offset: 0),
    OutlineEntry(text: '相遇', level: 2, offset: 10),
    OutlineEntry(text: '细节', level: 3, offset: 30),
  ];

  testWidgets('渲染标题列表并回调点击跳转', (tester) async {
    OutlineEntry? jumped;
    await tester.pumpWidget(
      wrap(
        OutlinePanel(
          entries: entries,
          activeIndex: 0,
          onJump: (e) => jumped = e,
        ),
      ),
    );
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('相遇'), findsOneWidget);
    await tester.tap(find.text('细节'));
    expect(jumped, entries[2]);
  });

  testWidgets('层级缩进递增', (tester) async {
    await tester.pumpWidget(
      wrap(OutlinePanel(entries: entries, activeIndex: -1, onJump: (_) {})),
    );
    double leftOf(String text) =>
        tester.getTopLeft(find.text(text)).dx;
    expect(leftOf('相遇'), greaterThan(leftOf('第一章')));
    expect(leftOf('细节'), greaterThan(leftOf('相遇')));
  });

  testWidgets('空态显示引导文案', (tester) async {
    await tester.pumpWidget(
      wrap(OutlinePanel(entries: const [], activeIndex: -1, onJump: (_) {})),
    );
    expect(find.text('使用 H1–H3 标题，这里会生成大纲'), findsOneWidget);
  });

  testWidgets('激活条目使用强调样式', (tester) async {
    await tester.pumpWidget(
      wrap(OutlinePanel(entries: entries, activeIndex: 1, onJump: (_) {})),
    );
    final active = tester.widget<Text>(find.text('相遇'));
    final normal = tester.widget<Text>(find.text('第一章'));
    expect(active.style!.fontWeight, FontWeight.w600);
    expect(normal.style!.fontWeight, FontWeight.w400);
    expect(active.style!.color, isNot(normal.style!.color));
  });
}
