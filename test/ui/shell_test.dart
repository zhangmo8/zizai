import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';
import 'package:zi_zai/ui/library_home.dart';
import 'package:zi_zai/ui/sidebar.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<(LibraryController, SettingsController)> makeApp({
    bool seed = false,
  }) async {
    final db = await Db.open(inMemoryDatabasePath);
    if (seed) {
      final nb = await db.createNotebook('小说');
      final doc = await db.createDocument(
        nb.id,
        title: '第一章',
        content: '[{"insert":"正文"}]',
      );
      await db.saveDocument(
        id: doc.id,
        title: doc.title,
        content: '[{"insert":"正文一二三"}]',
      );
      // 恢复进工作区依赖 last_open（与真实启动一致）。
      await db.saveLastOpen(notebookId: nb.id, documentId: doc.id, words: 0);
    }
    final settings = SettingsController(db);
    await settings.load();
    final library = LibraryController(db);
    await library.restore();
    return (library, settings);
  }

  Future<void> pumpAtSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 推进 FFI 数据库的真实异步写入及其返回后的 widget 刷新。
  Future<void> settleDatabaseWrite(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  testWidgets('空库：进入笔记本管理页（无工作区）', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    // 空库 → 笔记本管理页空态，无编辑器
    expect(find.byType(LibraryHome), findsOneWidget);
    expect(find.text('还没有笔记本'), findsOneWidget);
    expect(find.text('新建笔记本'), findsOneWidget);
    expect(find.byType(q.QuillEditor), findsNothing);
    expect(find.byType(Sidebar), findsNothing);
  });

  testWidgets('空库点「新建笔记本」→ 命名对话框 → 管理页出现卡片', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    await tester.tap(find.text('新建笔记本'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '我的小说');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleDatabaseWrite(tester);

    expect(find.text('我的小说'), findsOneWidget);
    expect(find.text('还没有笔记本'), findsNothing);
  });

  testWidgets('有书且 last_open：恢复进单书工作区，状态栏渲染今日进度与字数', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    final (library, settings) = (await tester.runAsync(
      () => makeApp(seed: true),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    expect(find.byType(LibraryHome), findsNothing);
    expect(find.byType(Sidebar), findsOneWidget);
    // 创建时含「正文」2 字；保存「正文一二三」5 字 → 今日增量 3
    expect(find.text('今日 3/2000'), findsOneWidget);
    expect(find.text('本文 5 字'), findsOneWidget);
    // 当前文档标题：侧边栏树行 + 编辑器区各一处
    expect(find.text('第一章'), findsNWidgets(2));
  });

  testWidgets('单书工作区：顶栏返回 → 回到笔记本管理页', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    final (library, settings) = (await tester.runAsync(
      () => makeApp(seed: true),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    expect(find.byType(Sidebar), findsOneWidget);
    await tester.tap(find.byTooltip('返回笔记本管理'));
    // closeNotebook 先 await 编辑器 beforeSwitchSave（真实写库），多轮推进后切回管理页。
    await settleDatabaseWrite(tester);
    expect(find.byType(LibraryHome), findsOneWidget);
    expect(find.byType(Sidebar), findsNothing);
    expect(library.currentNotebook, isNull);
  });

  testWidgets('Ctrl/Cmd+B 切换侧边栏显隐（桌面）', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    final (library, settings) = (await tester.runAsync(
      () => makeApp(seed: true),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    expect(find.byType(Sidebar), findsOneWidget);

    final mod = Platform.isMacOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    Future<void> pressB() async {
      await tester.sendKeyDownEvent(mod);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(mod);
      await tester.pump();
    }

    await pressB();
    expect(find.byType(Sidebar), findsNothing);
    await pressB();
    expect(find.byType(Sidebar), findsOneWidget);
  });

  testWidgets('顶栏侧边栏按钮切换侧边栏显隐（桌面）', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    final (library, settings) = (await tester.runAsync(
      () => makeApp(seed: true),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    expect(find.byType(Sidebar), findsOneWidget);
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl';
    await tester.tap(find.byTooltip('收起侧边栏 ($mod+B)'));
    await tester.pump();
    expect(find.byType(Sidebar), findsNothing);
    await tester.tap(find.byTooltip('展开侧边栏 ($mod+B)'));
    await tester.pump();
    expect(find.byType(Sidebar), findsOneWidget);
  });
}
