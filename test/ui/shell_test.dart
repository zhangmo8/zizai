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
import 'package:zi_zai/ui/focus_view.dart';
import 'package:zi_zai/ui/library_home.dart';
import 'package:zi_zai/ui/sidebar.dart';
import 'package:zi_zai/util/platform.dart';

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
      // last_open 存进书后恢复章节的依据（启动不自动进书，见 restore）。
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

  testWidgets('启动：有书也停在书架页；点书进工作区并恢复上次章节', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    final (library, settings) = (await tester.runAsync(
      () => makeApp(seed: true),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    // 启动 → 笔记本管理页（书架），不自动进书
    expect(find.byType(LibraryHome), findsOneWidget);
    expect(find.byType(Sidebar), findsNothing);
    expect(library.currentNotebook, isNull);

    // 从书架点书 → 进入单书工作区，恢复上次打开的章节
    await tester.tap(find.text('小说').first);
    await settleDatabaseWrite(tester);
    expect(find.byType(LibraryHome), findsNothing);
    expect(find.byType(Sidebar), findsOneWidget);
    // 创建时含「正文」2 字；保存「正文一二三」5 字 → 今日增量 3
    expect(find.text('今日 3/2000'), findsOneWidget);
    expect(find.text('本文 5 字'), findsOneWidget);
    // 当前文档标题：侧边栏树行 + 编辑器区各一处
    expect(find.text('第一章'), findsNWidgets(2));
  });

  /// 从书架点书进入单书工作区（makeApp(seed) 启动停在书架后使用）。
  /// 内存库跨测试共享可能累积多本同名「小说」，点第一本即可。
  Future<void> enterBookFromShelf(WidgetTester tester) async {
    await tester.tap(find.text('小说').first);
    await settleDatabaseWrite(tester);
    expect(find.byType(Sidebar), findsOneWidget);
  }

  testWidgets('单书工作区：顶栏返回 → 回到笔记本管理页', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    final (library, settings) = (await tester.runAsync(
      () => makeApp(seed: true),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    await enterBookFromShelf(tester);
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

    await enterBookFromShelf(tester);
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

    await enterBookFromShelf(tester);
    expect(find.byType(Sidebar), findsOneWidget);
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl';
    await tester.tap(find.byTooltip('收起侧边栏 ($mod+B)'));
    await tester.pump();
    expect(find.byType(Sidebar), findsNothing);
    await tester.tap(find.byTooltip('展开侧边栏 ($mod+B)'));
    await tester.pump();
    expect(find.byType(Sidebar), findsOneWidget);
  });

  // ── 移动端（Android）返回键：声明式门控无 Navigator 栈，返回键由 Shell
  // 的 PopScope 拦截（先关 Drawer/退沉浸，再回书架），绝不直接退出 App。

  /// 移动端窄窗 + 平台覆盖：走 Android Drawer 形态，返回已进工作区的 library。
  Future<LibraryController> pumpMobile(WidgetTester tester) async {
    debugIsDesktopPlatformOverride = false;
    addTearDown(() => debugIsDesktopPlatformOverride = null);
    await pumpAtSize(tester, const Size(480, 900));
    final (library, settings) = (await tester.runAsync(
      () => makeApp(seed: true),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();
    await tester.tap(find.text('小说').first);
    await settleDatabaseWrite(tester);
    // 移动端 Sidebar 在 Drawer 内，未打开时不上树 → 以门控状态断言工作区。
    expect(find.byType(LibraryHome), findsNothing);
    expect(library.currentNotebook, isNotNull);
    expect(find.byType(q.QuillEditor), findsOneWidget);
    return library;
  }

  /// 模拟 Android 系统返回键（WidgetsBinding 的 popRoute 消息路径）。
  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
  }

  testWidgets('移动端：工作区系统返回 → 回书架，不退出 App', (tester) async {
    final library = await pumpMobile(tester);

    await systemBack(tester);
    await settleDatabaseWrite(tester);

    expect(find.byType(LibraryHome), findsOneWidget);
    expect(find.byType(Sidebar), findsNothing);
    expect(library.currentNotebook, isNull);
  });

  testWidgets('移动端：Drawer 打开时系统返回 → 只关 Drawer，留在工作区', (tester) async {
    final library = await pumpMobile(tester);

    // 顶栏侧边栏按钮打开 Drawer（移动端 = openDrawer）。
    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('新建章节'), findsOneWidget); // Drawer 内容已上树

    await systemBack(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // Drawer 关闭，但仍在工作区（未回书架、未退 App）。
    expect(find.text('新建章节'), findsNothing);
    expect(find.byType(LibraryHome), findsNothing);
    expect(library.currentNotebook, isNotNull);
  });

  testWidgets('移动端：沉浸模式系统返回 → 退出沉浸，不退出笔记本', (tester) async {
    final library = await pumpMobile(tester);

    // Ctrl+Shift+F 进入沉浸（编辑器全局快捷键）。
    await tester.tap(find.byType(q.QuillEditor));
    await tester.pump();
    final mod = Platform.isMacOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(mod);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(mod);
    await tester.pump();
    expect(find.byType(FocusView), findsOneWidget);
    expect(find.byType(Sidebar), findsNothing);

    await systemBack(tester);

    // 退出沉浸：FocusView.focusMode=false（其 widget 常驻树中），chrome 恢复；
    // 仍是工作区（未回书架、未退 App）。移动端 Sidebar 在 Drawer 内不上树，
    // 以状态栏（沉浸时隐藏）恢复为准。
    final focusView = tester.widget<FocusView>(find.byType(FocusView));
    expect(focusView.focusMode, isFalse);
    expect(find.textContaining('今日'), findsOneWidget);
    expect(library.currentNotebook, isNotNull);
  });
}
