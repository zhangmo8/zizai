import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';

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

  testWidgets('桌面尺寸：渲染侧边栏 + 空态引导 + 状态栏', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    // FFI 数据库是真实异步，须在 runAsync 中完成（FakeAsync 不推进真实 I/O）。
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    // 侧边栏空库引导
    expect(find.text('新建一本笔记本，开始写'), findsOneWidget);
    expect(find.text('新建笔记本'), findsOneWidget);
    // 编辑器区空态 = Quill 编辑器（占位「从这里开始写…」由编辑器渲染）
    expect(find.byType(q.QuillEditor), findsOneWidget);
    // 状态栏：今日 0/2000（默认目标）+ 本文 0 字
    expect(find.text('今日 0/2000'), findsOneWidget);
    expect(find.text('本文 0 字'), findsOneWidget);
    // 桌面形态无 Drawer
    expect(find.byType(Drawer), findsNothing);
  });

  testWidgets('手机尺寸：Drawer 形态 + 状态栏', (tester) async {
    await pumpAtSize(tester, const Size(390, 844));
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    // Scaffold 挂载 Drawer（左滑入形态）
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.drawer, isNotNull);
    // 左边缘右滑打开 Drawer → 空库引导可见
    await tester.dragFrom(const Offset(5, 400), const Offset(350, 0));
    await tester.pumpAndSettle();
    expect(find.text('还没有笔记本'), findsNothing);
    expect(find.text('新建笔记本'), findsOneWidget);
    // 编辑器全宽显示 Quill 编辑器
    expect(find.byType(q.QuillEditor), findsOneWidget);
    expect(find.text('今日 0/2000'), findsOneWidget);
  });

  testWidgets('空库点「新建笔记本」→ 侧边栏出现笔记本', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    await tester.tap(find.text('新建笔记本'));
    await tester.pump();
    // 空态按钮 → 行内编辑（默认名「新笔记本」），Enter 确认
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // 行内提交等待真实 FFI 数据库写入；多轮推进异步 continuation 后刷新 UI。
    await settleDatabaseWrite(tester);
    expect(find.text('新笔记本'), findsOneWidget);
    expect(find.text('新建一本笔记本，开始写'), findsNothing);
  });

  testWidgets('有数据：状态栏渲染今日进度与文档字数', (tester) async {
    await pumpAtSize(tester, const Size(1200, 800));
    final (library, settings) = (await tester.runAsync(
      () => makeApp(seed: true),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    // 创建时含「正文」2 字；保存「正文一二三」5 字 → 今日增量 3
    expect(find.text('今日 3/2000'), findsOneWidget);
    // 本文显示快照字数
    expect(find.text('本文 5 字'), findsOneWidget);
    // 当前文档标题：侧边栏树行 + 编辑器区各一处
    expect(find.text('第一章'), findsNWidgets(2));
  });
}
