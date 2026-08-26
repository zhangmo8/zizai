import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';
import 'package:zi_zai/ui/status_bar.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('窄窗口（360dp）状态栏不溢出（会话 chip + 进度条 + 字数同屏）', (tester) async {
    final db = await tester.runAsync(() => Db.open(inMemoryDatabasePath));
    await tester.runAsync(() async {
      final nb = await db!.createNotebook('小说');
      final doc = await db.createDocument(
        nb.id,
        title: '第一章',
        content: '[{"insert":"正文"}]',
      );
      await db.saveDocument(
        id: doc.id,
        title: doc.title,
        content: '[{"insert":"正文一二三四五六七八九十"}]',
      );
      await db.saveLastOpen(notebookId: nb.id, documentId: doc.id, words: 0);
    });
    final settings = SettingsController(db!);
    await tester.runAsync(() => settings.load());
    final library = LibraryController(db);
    await tester.runAsync(() => library.restore());
    // 本次写作有增量 → 会话 chip 出现（状态栏最宽的组合之一）。
    library.session.onWordsWritten(100);

    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StatusBar(library: library, settings: settings),
        ),
      ),
    );
    await tester.pump();

    // 修复前此 Row 固定宽度合计超 360 → RenderFlex 溢出黄线；现应无异常。
    expect(tester.takeException(), isNull);
    expect(find.textContaining('今日'), findsOneWidget);
    expect(find.textContaining('本文'), findsOneWidget);
    await tester.runAsync(() async {
      library.session.dispose();
      await db.close();
    });
  });
}
