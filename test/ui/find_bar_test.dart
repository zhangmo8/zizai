import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/ui/find_bar.dart';

void main() {
  testWidgets('输入触发查询回调；Enter 下一个；展开替换后可全部替换', (tester) async {
    String? query;
    var next = 0;
    var prev = 0;
    String? replaced;
    String? replacedAll;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: StatefulBuilder(
              builder: (context, setState) => FindBar(
                matchCount: query == null || query!.isEmpty ? 0 : 3,
                currentIndex: query == null || query!.isEmpty ? -1 : 0,
                onQueryChanged: (v) => setState(() => query = v),
                onNext: () => next++,
                onPrev: () => prev++,
                onReplace: (r) => replaced = r,
                onReplaceAll: (r) => replacedAll = r,
                onClose: () => closed = true,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField).first, '他');
    await tester.pump();
    expect(query, '他');
    expect(find.text('1/3'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(next, 1);

    // 展开替换行
    await tester.tap(find.byTooltip('展开替换'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '她');
    await tester.tap(find.text('替换'));
    expect(replaced, '她');
    await tester.tap(find.text('全部替换'));
    expect(replacedAll, '她');
    expect(prev, 0);

    await tester.tap(find.byTooltip('关闭 (Esc)'));
    expect(closed, isTrue);
  });

  testWidgets('无结果态与按钮置灰', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            child: FindBar(
              matchCount: 0,
              currentIndex: -1,
              initialQuery: 'xx',
              onQueryChanged: (_) {},
              onNext: () => fail('无匹配不应触发下一个'),
              onPrev: () {},
              onReplace: (_) {},
              onReplaceAll: (_) {},
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('无结果'), findsOneWidget);
    await tester.tap(find.byTooltip('下一个 (Enter)'));
    await tester.pump();
  });
}
