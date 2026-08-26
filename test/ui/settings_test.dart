import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/app_logger.dart';
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
    // 启动停在书架；测试功能需要进书：恢复进工作区（与旧启动行为一致）。
    if (seed) {
      await library.openNotebook(library.notebooks.first.id);
    }
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

  /// 排空 sqflite 真实异步落库队列（25×40ms≈1s，同 shell_test.settleDatabaseWrite；
  /// 5 轮在 CI 慢机上偶发未落盘，见「恢复默认」注释）。
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  Future<void> openSettings(WidgetTester tester) async {
    // 全局设置入口已移到笔记本管理页顶栏：单书工作区内先返回管理层再打开。
    final back = find.byTooltip('返回笔记本管理');
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back);
      // closeNotebook 先 await 编辑器 beforeSwitchSave（真实写库），多轮推进后切回管理页。
      await drain(tester);
    }
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
  }

  Future<void> openCategory(WidgetTester tester, String category) async {
    await tester.tap(find.text(category).first);
    await tester.pumpAndSettle();
  }

  /// 打开侧边栏顶栏的「写作设置」对话框。
  Future<void> openBookSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('写作设置'));
    await tester.pumpAndSettle();
  }

  testWidgets('全局设置入口（管理页顶栏）→ 对话框出现，含各区块', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);

    expect(find.text('设置'), findsWidgets);
    expect(find.text('外观'), findsWidgets);
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
    await drain(tester);
    expect(settings.settings.fontSize, greaterThan(before));

    // 预览文本应用了字号
    final preview = tester.widget<Text>(find.textContaining('预览：'));
    expect(preview.style?.fontSize, settings.settings.fontSize);
    // 排空 sqflite 落库队列（见「恢复默认」测试注释），避免定时器残留 flake。
    await tester.runAsync(() => settings.load());
  });

  testWidgets('每日目标输入 → 状态栏进度即时刷新', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openBookSettings(tester);

    await tester.enterText(find.byType(TextField).first, '3000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await drain(tester);

    final notebookId = library.currentNotebook!.id;
    expect(settings.goalForNotebook(notebookId).words, 3000);
    // 关闭对话框后状态栏反映新目标
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('今日 0/3000'), findsOneWidget);
  });

  testWidgets('非法目标输入不生效', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openBookSettings(tester);

    await tester.enterText(find.byType(TextField).first, '50'); // 低于下限
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final notebookId = library.currentNotebook!.id;
    expect(settings.goalForNotebook(notebookId).words, 2000); // 不变
  });

  testWidgets('笔记本目标可关闭，关闭后状态栏隐藏进度', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openBookSettings(tester);

    await tester.tap(find.byType(ZzSwitch).first); // 启用今日目标
    await tester.pump();
    await drain(tester);
    final notebookId = library.currentNotebook!.id;
    expect(settings.goalForNotebook(notebookId).enabled, isFalse);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.textContaining('今日'), findsNothing);
  });

  testWidgets('焦点暗淡开关 → 即改即存并持久化', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);
    await openCategory(tester, '外观');

    expect(settings.settings.focusDim, isFalse);

    // 定位「暗淡非当前行」所在行的开关（与该行 label 同处一行）。
    final row = find
        .ancestor(
          of: find.text('暗淡非当前行'),
          matching: find.byWidgetPredicate((w) => w is Row),
        )
        .first;
    final dimSwitch = find.descendant(of: row, matching: find.byType(ZzSwitch));
    expect(dimSwitch, findsOneWidget);

    // 写作辅助组在设置页底部，确保开关进入视口后再点（CI 文本度量不同可能越界）。
    await tester.ensureVisible(dimSwitch);
    await tester.pumpAndSettle();
    await tester.tap(dimSwitch);
    await tester.pump();
    // 让真实异步写库完成（sqflite 事务在 FakeAsync 内不会自行结束）
    await drain(tester);
    expect(settings.settings.focusDim, isTrue);
    // 持久化：重新加载
    await tester.runAsync(() => settings.load());
    expect(settings.settings.focusDim, isTrue);
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
    // 无文档时工作区不可达（进管理页），直接渲染设置视图验证数据区。
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: SettingsView(settings: settings, library: library)),
      ),
    );
    await tester.pump();
    await openCategory(tester, '数据');

    expect(find.text('先打开一个文档'), findsOneWidget);
    expect(find.widgetWithText(ZzButton, '导出'), findsNothing);
  });

  testWidgets('数据区展示诊断日志路径与打开入口', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('zizai_settings_logger'),
    ))!;
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final logger = (await tester.runAsync(() => AppLogger.create(dir)))!;
    await tester.runAsync(() => logger.info('test.ready'));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SettingsView(
            settings: settings,
            library: library,
            logger: logger,
          ),
        ),
      ),
    );
    await tester.pump();
    await openCategory(tester, '数据');

    expect(find.text('诊断日志'), findsOneWidget);
    expect(find.text(logger.path), findsOneWidget);
    expect(find.widgetWithText(ZzButton, '打开目录'), findsNWidgets(2));
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
    await drain(tester);
    expect(settings.settings.theme, 'system');
    // 文档仍在
    expect(library.notebooks, hasLength(1));
    expect(library.documentsOf(library.notebooks.first.id), hasLength(1));
    // 确定性排空 sqflite 队列：update/resetNotebookGoals 是「先改内存再落库」，
    // 落库经 txnSynchronized 会挂 10s 超时定时器；先多轮推进真实 I/O，再
    // load() 排队等待之前的事务完成，避免测试结束时仍残留定时器
    // （!timersPending flake，CI 慢机偶发）。
    await drain(tester);
    await tester.runAsync(() => settings.load());
  });

  testWidgets('Esc 关闭设置对话框', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);
    expect(find.text('恢复默认'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('恢复默认'), findsNothing);
    expect(find.text('外观'), findsNothing);
  });

  testWidgets('状态栏今日进度点击 → 打开写作设置并聚焦每日目标', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    expect(find.text('今日 0/2000'), findsOneWidget);

    await tester.tap(find.text('今日 0/2000'));
    await tester.pumpAndSettle();

    // 「写作设置」对话框打开，每日目标输入框获得焦点
    expect(find.textContaining('写作设置'), findsOneWidget);
    expect(find.text('每日目标字数'), findsOneWidget);
    final goalField = tester.widget<TextField>(find.byType(TextField).first);
    expect(goalField.focusNode?.hasFocus, isTrue);
    // 排空 sqflite 落库队列，避免定时器残留 flake。
    await tester.runAsync(() => settings.load());
  });

  testWidgets('写作设置：行首自动缩进开关即改即存并持久化', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openBookSettings(tester);

    final nbId = library.notebooks.single.id;
    expect(settings.indentForNotebook(nbId), isFalse);

    final row = find
        .ancestor(
          of: find.text('行首自动缩进'),
          matching: find.byWidgetPredicate((w) => w is Row),
        )
        .first;
    final indentSwitch = find.descendant(
      of: row,
      matching: find.byType(ZzSwitch),
    );
    expect(indentSwitch, findsOneWidget);

    await tester.tap(indentSwitch);
    await tester.pump();
    await drain(tester);
    expect(settings.indentForNotebook(nbId), isTrue);
    // 持久化：重新加载。
    await tester.runAsync(() => settings.load());
    expect(settings.indentForNotebook(nbId), isTrue);
    // 排空 sqflite 落库队列，避免定时器残留 flake。
    await tester.runAsync(() => settings.load());
  });

  testWidgets('关于区：快捷键说明面板打开与关闭', (tester) async {
    final (library, settings) = (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings);
    await openSettings(tester);

    // 关于分类常驻（不依赖 updateChecker 接线）。
    await openCategory(tester, '关于');
    expect(find.text('快捷键说明'), findsOneWidget);

    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    // 面板标题与分组条目。
    expect(find.text('快捷键'), findsOneWidget);
    expect(find.text('切换侧边栏'), findsOneWidget);
    expect(find.text('全书搜索'), findsOneWidget);
    expect(find.text('沉浸模式'), findsOneWidget);
    // 键位块渲染（macOS 显示 ⌘，其余 Ctrl）。
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl';
    expect(find.text(mod), findsWidgets);
    expect(find.text('B'), findsOneWidget);

    // 关闭按钮收起面板。
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('切换侧边栏'), findsNothing);
  });
}
