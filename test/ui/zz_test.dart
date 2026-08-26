import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/ui/zz.dart';

void main() {
  testWidgets('ZzIconButton：icon 中心与按钮中心重合（Stack 角标回归守护）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: ZzIconButton(
              tooltip: '新建',
              icon: Icons.add,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    final button = tester.getRect(find.byType(ZzIconButton));
    final icon = tester.getRect(find.byIcon(Icons.add));
    // ec6ce37 加角标引入 Stack 后曾遗漏 alignment（默认 topStart），
    // icon 会贴左上角偏 5px；断言中心重合即回归守卫。
    expect((icon.center.dx - button.center.dx).abs(), lessThan(0.5));
    expect((icon.center.dy - button.center.dy).abs(), lessThan(0.5));
  });

  testWidgets('窄窗口长 toast 不产生 RenderFlex 溢出', (tester) async {
    tester.view.physicalSize = const Size(220, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showZzToast(
              context,
              '安装包校验失败，这是一条很长的错误信息，用于确认窄窗口也不会出现黄色溢出线',
              error: true,
            ),
            child: const Text('显示'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('显示'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });
}
