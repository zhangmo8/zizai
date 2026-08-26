import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/mcp_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';
import 'package:zi_zai/ui/settings_view.dart';
import 'package:zi_zai/ui/zz.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  testWidgets('设置「AI 协作」区：开关启停服务、地址与复制 skill 可见', (tester) async {
    final db = await tester.runAsync(() => Db.open(inMemoryDatabasePath));
    final settings = SettingsController(db!);
    await tester.runAsync(() => settings.load());
    final library = LibraryController(db);
    await tester.runAsync(() => library.restore());
    final mcp = McpController(db, initialPort: 0);
    await tester.runAsync(() => mcp.init());

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SettingsView(settings: settings, library: library, mcp: mcp),
        ),
      ),
    );
    await tester.pump();

    // 分类导航出现「AI 协作」，切过去。
    await tester.tap(find.text('AI 协作').first);
    await tester.pumpAndSettle();

    // 初始关闭态：无地址、状态「已停止」。
    expect(find.text('启用本地服务'), findsOneWidget);
    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('复制 skill'), findsOneWidget);
    expect(find.textContaining('http://127.0.0.1:'), findsNothing);

    // 打开开关 → 服务运行（真实端口绑定需 runAsync 推进）。
    await tester.tap(find.byType(ZzSwitch).last);
    await drain(tester);
    expect(mcp.running, isTrue);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.textContaining('http://127.0.0.1:'), findsOneWidget);

    // 复制 skill 按钮存在（点击不炸即可）；toast 定时器走完。
    await tester.tap(find.text('复制 skill'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));

    // 关闭开关 → 停止。
    await tester.tap(find.byType(ZzSwitch).last);
    await drain(tester);
    expect(mcp.running, isFalse);
    expect(find.text('已停止'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    await tester.runAsync(() async {
      mcp.dispose();
      await db.close();
    });
  });
}
