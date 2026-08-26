import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';
import 'package:zi_zai/ui/library_home.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<(LibraryController, SettingsController)> makeApp({
    List<(String, List<String>)> tree = const [],
  }) async {
    final dir = await Directory.systemTemp.createTemp('zizai_home');
    final db = await Db.open('${dir.path}/test.db');
    for (final (nbName, docs) in tree) {
      final nb = await db.createNotebook(nbName);
      for (final docTitle in docs) {
        final doc = await db.createDocument(nb.id, title: docTitle);
        await db.saveDocument(
          id: doc.id,
          title: doc.title,
          content: '[{"insert":"正文一二三"}]',
          writtenWords: 5,
        );
      }
    }
    final settings = SettingsController(db);
    await settings.load();
    final library = LibraryController(db);
    await library.restore();
    return (library, settings);
  }

  Future<void> pumpHome(
    WidgetTester tester,
    LibraryController library,
    SettingsController settings,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: LibraryHome(library: library, settings: settings),
      ),
    );
    await tester.pump();
  }

  /// 推进 FFI 数据库真实异步写库。
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  testWidgets('空库：空态引导 + 新建按钮', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpHome(tester, library, settings);

    expect(find.text('笔记本'), findsOneWidget);
    expect(find.text('还没有笔记本'), findsOneWidget);
    expect(find.text('新建笔记本'), findsOneWidget);
  });

  testWidgets('网格：卡片显示书名 + 章节数/字数，无封面', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章']), ('随笔', [])]),
    ))!;
    await pumpHome(tester, library, settings);

    expect(find.text('小说'), findsOneWidget);
    expect(find.text('随笔'), findsOneWidget);
    expect(find.text('2 章 · 10 字'), findsOneWidget); // 2×5 字
    expect(find.text('0 章 · 0 字'), findsOneWidget);
    // 无封面：不渲染图片封面
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('视图切换：grid ↔ list（带过渡动画 + 持久化）', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章']), ('随笔', [])]),
    ))!;
    await pumpHome(tester, library, settings);

    // 默认网格（卡片容器）；切列表 → 行容器（tap 触发 setHomeView 落库，需 drain）
    await tester.tap(find.byTooltip('列表视图'));
    await tester.pump();
    await drain(tester);
    expect(find.byTooltip('网格视图'), findsOneWidget);
    // 列表行内仍有书名
    expect(find.text('小说'), findsOneWidget);
    // 切回网格
    await tester.tap(find.byTooltip('网格视图'));
    await tester.pump();
    await drain(tester);
    expect(find.byTooltip('列表视图'), findsOneWidget);
    // 视图选择已持久化：重建后仍是网格
    final settings2 = SettingsController(settings.db);
    await tester.runAsync(() => settings2.load());
    expect(settings2.homeView, 'grid');
  });

  testWidgets('新建笔记本：对话框命名 → 卡片出现', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpHome(tester, library, settings);

    await tester.tap(find.text('新建笔记本'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '新书');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await drain(tester);

    expect(find.text('新书'), findsOneWidget);
    expect(find.text('还没有笔记本'), findsNothing);
  });

  testWidgets('点书 → openNotebook（进入单书工作区）', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章'])]),
    ))!;
    await pumpHome(tester, library, settings);

    await tester.tap(find.text('小说'));
    await drain(tester);
    expect(library.currentNotebook?.name, '小说');
    expect(library.currentDocument?.title, '第一章');
  });

  testWidgets('改名/删除：⋮ 菜单', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', [])]),
    ))!;
    await pumpHome(tester, library, settings);

    // 改名
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '改名书');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await drain(tester);
    expect(library.notebooks.single.name, '改名书');
    expect(find.text('改名书'), findsOneWidget);

    // 删除
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last); // 确认删除
    await tester.pumpAndSettle();
    await drain(tester);
    expect(library.notebooks, isEmpty);
    expect(find.text('还没有笔记本'), findsOneWidget);
  });
}
