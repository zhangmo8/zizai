import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/models.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';
import 'package:zi_zai/ui/settings_view.dart';
import 'package:zi_zai/ui/zz.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<(LibraryController, SettingsController)> makeApp({
    bool seed = true,
  }) async {
    final dir = await Directory.systemTemp.createTemp('zizai_settings');
    final db = await Db.open('${dir.path}/test.db');
    if (seed) {
      final nb = await db.createNotebook('小说');
      final doc = await db.createDocument(
        nb.id,
        title: '第一章',
        content: '[{"insert":"正文"}]',
      );
      await db.saveLastOpen(notebookId: nb.id, documentId: doc.id, words: 2);
    }
    final settings = SettingsController(db);
    await settings.load();
    final library = LibraryController(db);
    await library.restore();
    return (library, settings);
  }

  Future<void> pumpApp(
    WidgetTester tester,
    LibraryController library,
    SettingsController settings,
  ) async {
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
  }

  Future<void> openCategory(WidgetTester tester, String category) async {
    await tester.tap(find.text(category).first);
    await tester.pumpAndSettle();
  }

  testWidgets('侧边栏设置入口 → 对话框出现，含各区块', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);

    expect(find.text('设置'), findsWidgets);
    expect(find.text('外观'), findsWidgets);
    expect(find.text('写作'), findsOneWidget);
    expect(find.text('数据'), findsOneWidget);
    expect(find.text('恢复默认'), findsOneWidget);
    expect(find.text('关闭'), findsNothing); // 桌面端仅保留右上角关闭按钮
  });

  testWidgets('主题切换 → 即改即存并持久化', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);

    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').last);
    await tester.pumpAndSettle();

    expect(settings.settings.theme, 'dark');
    // 持久化：重新加载
    await tester.runAsync(() => settings.load());
    expect(settings.settings.theme, 'dark');
  });

  testWidgets('字号 Slider 拖动 → fontSize 更新 + 预览字号同步', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);

    final slider = find.byType(Slider).first; // 字号
    final before = settings.settings.fontSize;
    // 直接驱动 onChanged，避免依赖容器尺寸的拖拽坐标。
    final material = tester.widget<Slider>(slider);
    material.onChanged?.call(before + 2);
    await tester.pump();
    // 让真实异步写库完成（sqflite 事务在 FakeAsync 内不会自行结束）
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
    expect(settings.settings.fontSize, greaterThan(before));

    // 预览文本应用了字号
    final preview = tester.widget<Text>(find.textContaining('预览：'));
    expect(preview.style?.fontSize, settings.settings.fontSize);
  });

  testWidgets('每日目标输入 → 状态栏进度即时刷新', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);
    await openCategory(tester, '写作');

    await tester.enterText(
      find.descendant(
        of: find.byType(SettingsView),
        matching: find.byType(TextField),
      ),
      '3000',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final notebookId = library.currentDocument!.notebookId;
    expect(settings.goalForNotebook(notebookId).words, 3000);
    // 关闭设置后状态栏反映新目标
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('今日 0/3000'), findsOneWidget);
  });

  testWidgets('非法目标输入不生效', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);
    await openCategory(tester, '写作');

    await tester.enterText(
      find.descendant(
        of: find.byType(SettingsView),
        matching: find.byType(TextField),
      ),
      '50',
    ); // 低于下限
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final notebookId = library.currentDocument!.notebookId;
    expect(settings.goalForNotebook(notebookId).words, 2000); // 不变
  });

  testWidgets('笔记本目标可关闭，关闭后状态栏隐藏进度', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);
    await openCategory(tester, '写作');

    await tester.tap(find.byType(ZzSwitch));
    await tester.pump();
    final notebookId = library.currentDocument!.notebookId;
    expect(settings.goalForNotebook(notebookId).enabled, isFalse);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.textContaining('今日'), findsNothing);
  });

  testWidgets('导出：有文档可用且回调收到当前文档', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    Document? exported;
    var exportedText = '';
    // 直接构造带注入导出的设置视图（通过对话框测试不方便注入）
    final view = SettingsView(
      settings: settings,
      library: library,
      exporter: (doc, text) async {
        exported = doc;
        exportedText = text;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: view),
      ),
    );
    await tester.pump();

    await openCategory(tester, '数据');
    await tester.tap(find.widgetWithText(ZzButton, '导出'));
    await tester.pumpAndSettle();
    expect(exported?.title, '第一章');
    expect(exportedText, '正文');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('导出：无文档时禁用并说明', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(seed: false),
    ))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);
    await openCategory(tester, '数据');

    expect(find.text('先打开一个文档'), findsOneWidget);
    expect(find.widgetWithText(ZzButton, '导出'), findsNothing);
  });

  testWidgets('恢复默认：设置回默认值，不删文档', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);

    // 先改主题
    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('深色').last);
    await tester.pumpAndSettle();
    expect(settings.settings.theme, 'dark');

    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认').last);
    await tester.pumpAndSettle();
    // 让真实异步写库完成（sqflite 事务在 FakeAsync 内不会自行结束）
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
    expect(settings.settings.theme, 'system');
    // 文档仍在
    expect(library.notebooks, hasLength(1));
    expect(library.documentsOf(library.notebooks.first.id), hasLength(1));
  });
}
