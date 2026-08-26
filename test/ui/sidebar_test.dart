import 'dart:io';

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/models.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';
import 'package:zi_zai/ui/shell.dart';
import 'package:zi_zai/ui/sidebar.dart';
import 'package:zi_zai/ui/zz.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 让真实异步（DB I/O）完成，然后刷新 UI。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  Future<(LibraryController, SettingsController)> makeApp({
    List<(String, List<String>)> tree = const [],
  }) async {
    final dir = await Directory.systemTemp.createTemp('zizai_sidebar');
    final db = await Db.open('${dir.path}/test.db');
    for (final (nbName, docs) in tree) {
      final nb = await db.createNotebook(nbName);
      for (final docTitle in docs) {
        await db.createDocument(nb.id, title: docTitle);
      }
    }
    final settings = SettingsController(db);
    await settings.load();
    final library = LibraryController(db);
    await library.restore();
    return (library, settings);
  }

  /// 单书侧边栏：[notebookId] 为 null 时不打开书（顶栏空态）。
  Future<void> pumpSidebar(
    WidgetTester tester,
    LibraryController library,
    SettingsController settings, {
    String? notebookId,
    VoidCallback? onOpenBookSearch,
    VoidCallback? onBack,
  }) async {
    if (notebookId != null) {
      await tester.runAsync(() => library.openNotebook(notebookId));
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 800,
            child: Sidebar(
              library: library,
              settings: settings,
              onOpenBookSearch: onOpenBookSearch,
              onBack: onBack,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 完整工作区（Shell）：删除确认条渲染在编辑器区顶部。
  Future<void> pumpShell(
    WidgetTester tester,
    LibraryController library,
    SettingsController settings, {
    String? notebookId,
  }) async {
    if (notebookId != null) {
      await tester.runAsync(() => library.openNotebook(notebookId));
    }
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: Shell(library: library, settings: settings)),
    );
    await tester.pump();
  }

  /// 打开第 [index] 个行菜单（0 起，仅文档行）。
  Future<void> openRowMenu(WidgetTester tester, int index) async {
    final menu = find.byIcon(Icons.more_horiz).at(index);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.moveTo(tester.getCenter(menu));
    await tester.pump();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await gesture.removePointer();
  }

  Future<void> renameViaMenu(WidgetTester tester, String toName) async {
    await tester.tap(find.text('重命名'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), toName);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  group('suggestedChapterTitle', () {
    Document doc(String title) => Document(
          id: title,
          notebookId: 'nb',
          title: title,
          content: '{}',
          words: 0,
          position: 0,
          createdAt: 0,
          updatedAt: 0,
        );

    test('空笔记本 → 第 1 章', () {
      expect(suggestedChapterTitle(const <Document>[]), '第 1 章');
    });

    test('按整本章节数 +1（阿拉伯编号书）', () {
      expect(
        suggestedChapterTitle([doc('第 1 章'), doc('第 2 章')]),
        '第 3 章',
      );
      expect(
        suggestedChapterTitle([
          for (var i = 1; i <= 1008; i++) doc('第 $i 章'),
        ]),
        '第 1009 章',
      );
    });

    test('标题不含数字也照算（不再出现「新章节」）', () {
      expect(
        suggestedChapterTitle([doc('第 1 章'), doc('序章')]),
        '第 3 章',
      );
      expect(
        suggestedChapterTitle([doc('楔子'), doc('回归'), doc('下册开篇')]),
        '第 4 章',
      );
    });

    test('中文编号书 → 仍按整本章节数 +1（阿拉伯）', () {
      expect(
        suggestedChapterTitle([doc('第一章'), doc('第二章')]),
        '第 3 章',
      );
    });

    test('非连续编号 → 数量 +1 而非最大序号 +1', () {
      expect(
        suggestedChapterTitle([doc('第 1 章'), doc('第 5 章')]),
        '第 3 章',
      );
    });
  });

  group('reorderTarget 拖拽落点映射', () {
    TreeRowRef nb(String id) => TreeRowRef(notebookId: id, isHeader: true);
    TreeRowRef doc(String nbId, String docId) =>
        TreeRowRef(notebookId: nbId, docId: docId);
    TreeRowRef btn(String nbId) => TreeRowRef(notebookId: nbId);

    // 单书树（分卷头可视作 isHeader 行）：卷一, 一, 二, 新建
    final refs = [nb('A'), doc('A', 'd1'), doc('A', 'd2'), btn('A')];

    test('同书下移一位', () {
      expect(reorderTarget(refs, 1, 2), ('A', 1));
    });

    test('落点未变 → null（不写库）', () {
      expect(reorderTarget(refs, 1, 1), isNull);
    });

    test('分卷头不可拖', () {
      expect(reorderTarget(refs, 0, 1), isNull);
    });

    test('新建按钮行不可拖', () {
      expect(reorderTarget(refs, 3, 1), isNull);
    });
  });

  group('manualReorderTarget 手动分卷拖拽落点映射', () {
    TreeRowRef vh(String volId) =>
        TreeRowRef(notebookId: 'A', isVolumeHeader: true, volumeId: volId);
    TreeRowRef doc(String nbId, String docId, String? volId) =>
        TreeRowRef(notebookId: nbId, docId: docId, volumeId: volId);
    TreeRowRef uh() => TreeRowRef(notebookId: 'A', isUnassignedHeader: true);
    TreeRowRef btn() => TreeRowRef(notebookId: 'A');

    // 树：卷一[一,二], 卷二[三], 未分卷[四], 按钮
    final refs = [
      vh('v1'),
      doc('A', 'd1', 'v1'),
      doc('A', 'd2', 'v1'),
      vh('v2'),
      doc('A', 'd3', 'v2'),
      uh(),
      doc('A', 'd4', null),
      btn(),
    ];

    test('拖到卷头边界 → 移入该卷末尾', () {
      // d1 落到卷二头 → 卷二末尾（d3 之后）
      expect(manualReorderTarget(refs, 1, 2), ('A', 'v2', 1));
    });

    test('落到章节行上方 → 移入该章所在卷的对应序号', () {
      // d2 移到 d3 上方 → 卷二第 0 位（跨卷）
      expect(manualReorderTarget(refs, 2, 3), ('A', 'v2', 0));
      // d2 移到 d1 上方 → 卷一第 0 位（卷内重排）
      expect(manualReorderTarget(refs, 2, 1), ('A', 'v1', 0));
    });

    test('落到未分卷头 → 清卷（volumeId null，末尾）', () {
      expect(manualReorderTarget(refs, 1, 4), ('A', null, 1));
    });

    test('无拖动 / 同卷位置未变 → null（不写库）', () {
      expect(manualReorderTarget(refs, 1, 1), isNull); // d1 原地
      expect(manualReorderTarget(refs, 2, 2), isNull); // d2 原地
    });

    test('卷头/未分卷头/按钮不可拖', () {
      expect(manualReorderTarget(refs, 0, 1), isNull); // 卷头
      expect(manualReorderTarget(refs, 5, 1), isNull); // 未分卷头
      expect(manualReorderTarget(refs, 7, 1), isNull); // 按钮
    });

    test('落到列表末尾 → 最后一个分区末尾（未分卷）', () {
      expect(manualReorderTarget(refs, 1, 8), ('A', null, 1));
    });
  });

  testWidgets('拖拽排序：拖手柄同本书内重排', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);

    final grip = find.byIcon(Icons.drag_indicator).first;
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.moveTo(tester.getCenter(grip));
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.down(tester.getCenter(grip));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 18));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 18));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await gesture.removePointer();
    await settle(tester);

    expect(library.documentsOf(nbId).map((d) => d.title), ['第二章', '第一章']);
  });

  testWidgets('点击兼容：行体带轻微移动仍切换文档（不触发拖拽）', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    final second = find.text('第二章');
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.moveTo(tester.getCenter(second));
    await gesture.down(tester.getCenter(second));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 3));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await gesture.removePointer();
    await settle(tester);

    expect(library.currentDocument?.title, '第二章');
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);
  });

  testWidgets('点击拖拽手柄不切换文档、不重排', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);
    final openedDoc = library.currentDocument; // openNotebook 默认打开第一章
    expect(openedDoc, isNotNull);

    final grip = find.byIcon(Icons.drag_indicator).at(1); // 第二章的手柄
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.moveTo(tester.getCenter(grip));
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.down(tester.getCenter(grip));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await gesture.removePointer();
    await settle(tester);

    expect(library.currentDocument?.id, openedDoc!.id); // 未切换
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);
  });

  testWidgets('树渲染：书名头 + 章节 + 当前文档高亮', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await tester.runAsync(
      () => library.switchDocument(
        library.documentsOf(nbId).first.id,
      ),
    );
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    expect(find.text('小说'), findsOneWidget);
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('第二章'), findsOneWidget);
    expect(find.text('新建章节'), findsOneWidget);
  });

  testWidgets('空书：显示章节空态，点「新建第一章」生成', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', [])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    expect(find.text('这本书还没有章节'), findsOneWidget);
    await tester.tap(find.text('新建第一章'));
    await settle(tester);
    expect(library.documentsOf(nbId).map((d) => d.title), ['第 1 章']);
  });

  testWidgets('顶栏：返回 + 书名 + 本书设置 + 搜索按钮', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章'])]),
    ))!;
    var backed = 0;
    var searched = 0;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(
      tester,
      library,
      settings,
      notebookId: nbId,
      onBack: () => backed++,
      onOpenBookSearch: () => searched++,
    );

    expect(find.text('小说'), findsOneWidget);
    await tester.tap(find.byTooltip('返回笔记本管理'));
    expect(backed, 1);
    await tester.tap(find.byTooltip('写作设置'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('写作设置'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byIcon(Icons.search));
    expect(searched, 1);
  });

  testWidgets('新建章节：点击 + 直接生成，自动编号（不进入命名）', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第 1 章', '第 2 章', '第 3 章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    await tester.tap(find.text('新建章节').first);
    await settle(tester);

    expect(
      library.documentsOf(nbId).map((d) => d.title),
      ['第 1 章', '第 2 章', '第 3 章', '第 4 章'],
    );
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('重命名文档：⋮ → 重命名 → Enter', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    await openRowMenu(tester, 0);
    await renameViaMenu(tester, '新标题');
    await settle(tester);

    expect(find.text('新标题'), findsOneWidget);
    expect(find.text('第一章'), findsNothing);
    expect(library.documentsOf(nbId).map((d) => d.title), ['新标题']);
  });

  testWidgets('重名冲突：错误态不允许提交', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    await openRowMenu(tester, 1); // 第二章
    await renameViaMenu(tester, '第一章');
    expect(find.text('同名已存在'), findsOneWidget);
    await settle(tester);
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);
  });

  testWidgets('非法文件名（含 /）错误态', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章'])]),
    ))!;
    await pumpSidebar(tester, library, settings, notebookId: library.notebooks.first.id);

    await openRowMenu(tester, 0);
    await renameViaMenu(tester, 'a/b');
    expect(find.text('名称不能包含 / 或 \\'), findsOneWidget);
  });

  testWidgets('Esc 取消编辑，不产生变更', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    await openRowMenu(tester, 0);
    await tester.tap(find.text('重命名'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '临时');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('第一章'), findsOneWidget);
  });

  testWidgets('文档上移/下移', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);

    await openRowMenu(tester, 1); // 第二章上移
    await tester.tap(find.text('上移'));
    await settle(tester);
    expect(library.documentsOf(nbId).map((d) => d.title), ['第二章', '第一章']);

    await openRowMenu(tester, 0); // 第二章（当前在前）下移
    await tester.tap(find.text('下移'));
    await settle(tester);
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);
  });

  testWidgets('单击文档切换当前文档，先触发 beforeSwitchSave', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    var saved = false;
    library.beforeSwitchSave = () async {
      saved = true;
    };
    await pumpSidebar(tester, library, settings, notebookId: library.notebooks.first.id);

    await tester.tap(find.text('第二章'));
    await settle(tester);
    expect(saved, isTrue);
    expect(library.currentDocument?.title, '第二章');
  });

  testWidgets('删除文档：确认条出现 → 确认后移除', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpShell(tester, library, settings, notebookId: nbId);

    await openRowMenu(tester, 1); // 第二章
    await tester.tap(find.text('删除'));
    await tester.pump();

    expect(find.textContaining('删除《第二章》'), findsOneWidget);
    await tester.tap(find.text('确认删除'));
    await settle(tester);
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章']);
  });

  testWidgets('删除取消：5s 无操作自动关闭（不删除）', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpShell(tester, library, settings, notebookId: nbId);

    await openRowMenu(tester, 0);
    await tester.tap(find.text('删除'));
    await tester.pump();
    expect(find.textContaining('此操作不可恢复'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining('此操作不可恢复'), findsNothing);
    expect(library.pendingDeletion, isNull);
    expect(library.documentsOf(nbId), hasLength(1));
  });

  testWidgets('分卷：开启后按每卷章数插入卷标题', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章', '第三章', '第四章', '第五章']),
        ],
      ),
    ))!;
    final nbId = library.notebooks.first.id;
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, enabled: true, chapters: 2),
    );
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    // 5 章 / 每卷 2 章 → 第一卷、第二卷、第三卷
    expect(find.text('第一卷'), findsOneWidget);
    expect(find.text('第二卷'), findsOneWidget);
    expect(find.text('第三卷'), findsOneWidget);
    expect(find.text('第四章'), findsOneWidget);

    // 关闭后恢复平铺
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, enabled: false),
    );
    await tester.pump();
    expect(find.text('第一卷'), findsNothing);
  });

  testWidgets('分卷：关闭时平铺显示，且不显示视图切换/新建分卷按钮', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    // 分卷关闭 = 平铺：无卷头，顶栏不出现视图切换/新建分卷按钮
    expect(find.text('第一卷'), findsNothing);
    expect(find.text('第一章'), findsOneWidget);
    expect(find.byTooltip('平铺展示'), findsNothing);
    expect(find.byTooltip('分卷展示'), findsNothing);
    expect(find.byTooltip('新建分卷'), findsNothing);
  });

  testWidgets('手动分卷：从自动切换后自动建卷并归章，卷头可交互', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章', '第三章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, enabled: true, chapters: 2),
    );
    // 切手动：自动按每 2 章建卷并归章（幂等迁移）。
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, mode: VolumeMode.manual),
    );
    await tester.runAsync(() => library.refreshTree());
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    // 两卷，全部归章（无未分卷），章节仍在
    expect(library.volumesOf(nbId), hasLength(2));
    expect(find.text('第一卷'), findsOneWidget);
    expect(find.text('第二卷'), findsOneWidget);
    expect(find.text('未分卷'), findsNothing);
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('第三章'), findsOneWidget);
    // 手动分卷入口：顶栏「+ 新建分卷」icon
    expect(find.byTooltip('新建分卷'), findsOneWidget);
    // 章节数角标
    expect(find.text('2 章'), findsOneWidget);
    expect(find.text('1 章'), findsOneWidget);
    // 新建章节归入当前（最后）卷
    await tester.runAsync(() => library.switchDocument(
      library.documentsOf(nbId).first.id,
    ));
    await tester.pump();
    await tester.tap(find.text('新建章节'));
    await settle(tester);
    final newDoc = library.documentsOf(nbId).last;
    expect(newDoc.title, '第 4 章');
    expect(newDoc.volumeId, library.volumesOf(nbId).first.id);
  });

  testWidgets('手动分卷：章节菜单「移动到分卷」跨卷移动', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, enabled: true, chapters: 1),
    );
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, mode: VolumeMode.manual),
    );
    await tester.runAsync(() => library.refreshTree());
    await pumpSidebar(tester, library, settings, notebookId: nbId);
    final vols = library.volumesOf(nbId);
    expect(vols, hasLength(2));

    // 树中 ⋮ 顺序：卷一头, 第一章, 卷二头, 第二章（卷头自带菜单）
    await openRowMenu(tester, 1); // 第一章的菜单
    expect(find.text('移动到分卷'), findsOneWidget);
    await tester.tap(find.text('移动到分卷'));
    await tester.pumpAndSettle();
    // 二级菜单：只列卷（无「未分卷」），用 key 排除树里的卷头文本
    expect(find.text('未分卷'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('move-vol-第二卷')));
    await settle(tester);

    final moved = library.documentsOf(nbId).firstWhere(
      (d) => d.title == '第一章',
    );
    // 第一章 移入第二卷；第一卷清空，第二卷两章
    expect(moved.volumeId, vols[1].id);
    expect(
      library.documentsOf(nbId).where((d) => d.volumeId == vols[0].id),
      isEmpty,
    );
    expect(
      library.documentsOf(nbId).where((d) => d.volumeId == vols[1].id),
      hasLength(2),
    );
  });

  testWidgets('手动分卷：删除卷连带删除卷内章节，侧边栏不白屏', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, enabled: true, chapters: 1),
    );
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, mode: VolumeMode.manual),
    );
    await tester.runAsync(() => library.refreshTree());
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    // 删除第一卷：卷头 ⋮ → 删除卷 → 确认
    await openRowMenu(tester, 0);
    await tester.tap(find.text('删除卷'));
    await tester.pump();
    await tester.tap(find.text('删除'));
    await settle(tester);

    // 卷内章节随卷删除，剩下的章节归到唯一剩余卷；渲染无异常、无未分卷
    expect(tester.takeException(), isNull);
    expect(library.volumesOf(nbId), hasLength(1));
    expect(find.text('第一卷'), findsNothing);
    expect(find.text('未分卷'), findsNothing);
    expect(find.text('第一章'), findsNothing); // 第一卷的章节被删除
    expect(find.text('第二章'), findsOneWidget);
    final vols = library.volumesOf(nbId);
    expect(
      library.documentsOf(nbId).first.volumeId,
      vols.single.id,
    );
  });

  testWidgets('手动分卷：无卷时新建章节自动建卷', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', [])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, enabled: true, chapters: 5),
    );
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, mode: VolumeMode.manual),
    );
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    // 点击「新建第一章」→ 无卷时自动创建一个卷并归章
    await tester.tap(find.text('新建第一章'));
    await settle(tester);
    expect(library.volumesOf(nbId), hasLength(1));
    expect(find.text('第一卷'), findsOneWidget);
    expect(library.documentsOf(nbId).single.volumeId, library.volumesOf(nbId).single.id);
  });

  testWidgets('手动分卷：卷全删光但章节残留（旧版脏数据）不白屏', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    // 自动 → 手动建卷后，用旧版删卷（deleteVolume 只清归属、保留章节）
    // 把卷全部删光 → 模拟 v1.9.0 遗留脏数据：零卷 + 章节 volume_id = null。
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, enabled: true, chapters: 1),
    );
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, mode: VolumeMode.manual),
    );
    await tester.runAsync(() => library.refreshTree()); // 装载 ensureAutoVolumes 建的卷
    await tester.runAsync(() async {
      for (final vol in library.volumesOf(nbId).toList()) {
        await settings.db.deleteVolume(vol.id);
      }
    });
    await tester.runAsync(() => library.refreshTree());
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    // 零卷 + 残留章节 → 平铺渲染，不崩溃，章节可见
    expect(tester.takeException(), isNull);
    expect(library.volumesOf(nbId), isEmpty);
    expect(library.documentsOf(nbId), hasLength(2));
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('第二章'), findsOneWidget);
    // 顶栏仍有「新建分卷」可建卷恢复
    expect(find.byTooltip('新建分卷'), findsOneWidget);
  });

  testWidgets('视图切换：分卷展示 ↔ 平铺展示（顶栏图标 + tooltip）', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, enabled: true, chapters: 2),
    );
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    // 分卷展示：卷头可见
    expect(find.text('第一卷'), findsOneWidget);
    // 切平铺展示：卷头消失
    await tester.tap(find.byTooltip('平铺展示'));
    await tester.pump();
    await settle(tester);
    expect(settings.volumeViewGrouped, isFalse);
    expect(find.text('第一卷'), findsNothing);
    expect(find.text('第一章'), findsOneWidget);
    // 切回分卷展示
    await tester.tap(find.byTooltip('分卷展示'));
    await tester.pump();
    await settle(tester);
    expect(find.text('第一卷'), findsOneWidget);
  });

  testWidgets('自动分卷：卷头可重命名（自定义名存 settings）', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await tester.runAsync(
      () => settings.setVolumeForNotebook(nbId, enabled: true, chapters: 2),
    );
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    // 自动分卷卷头菜单：仅重命名
    await openRowMenu(tester, 0); // 第一卷的 ⋮
    expect(find.text('重命名'), findsOneWidget);
    expect(find.text('删除卷'), findsNothing);
    await renameViaMenu(tester, '上卷');
    expect(settings.autoVolumeName(nbId, 1), '上卷');
    expect(find.text('上卷'), findsOneWidget);
    expect(find.text('第一卷'), findsNothing);
  });

  testWidgets('写作设置：写作目标 + 段落缩进 + 分卷开关', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    await tester.tap(find.byTooltip('写作设置'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('写作目标'), findsOneWidget);
    expect(find.text('段落缩进'), findsOneWidget);
    expect(find.text('分卷'), findsOneWidget);

    // 开启分卷 → 每卷章数输入框出现
    await tester.tap(find.byType(ZzSwitch).at(2));
    await tester.pump();
    expect(find.text('每卷章数'), findsOneWidget);
    expect(settings.volumeForNotebook(nbId).enabled, isTrue);

    // 开启写作目标 → 每日目标字数出现
    if (!settings.goalForNotebook(nbId).enabled) {
      await tester.tap(find.byType(ZzSwitch).at(0));
      await tester.pump();
    }
    expect(find.text('每日目标字数'), findsOneWidget);
  });

  testWidgets('章节排序：倒序最新章在上，新建章节按钮随序列末尾端', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章', '第二章', '第三章'])]),
    ))!;
    final nbId = library.notebooks.first.id;

    // 正序（默认）：第一章在上
    await pumpSidebar(tester, library, settings, notebookId: nbId);
    expect(
      tester.getTopLeft(find.text('第一章')).dy <
          tester.getTopLeft(find.text('第三章')).dy,
      isTrue,
    );

    // 切倒序：第三章（最新）在上；「新建章节」按钮移到列表顶部
    await tester.runAsync(
      () => settings.setDocsOrder(nbId, 'desc'),
    );
    await tester.pump();
    await settle(tester);
    expect(
      tester.getTopLeft(find.text('第三章')).dy <
          tester.getTopLeft(find.text('第一章')).dy,
      isTrue,
    );
    expect(
      tester.getTopLeft(find.text('新建章节')).dy <
          tester.getTopLeft(find.text('第三章')).dy,
      isTrue,
    );

    // 倒序 + 新建章节 → 仍按整本章节数 +1 命名，追加在序列末尾（最新上方）
    await tester.tap(find.text('新建章节'));
    await settle(tester);
    expect(library.documentsOf(nbId), hasLength(4));
    expect(library.documentsOf(nbId).last.title, '第 4 章');
    expect(find.text('第 4 章'), findsOneWidget);

    // 切回正序恢复
    await tester.runAsync(
      () => settings.setDocsOrder(nbId, 'asc'),
    );
    await tester.pump();
    await settle(tester);
    expect(
      tester.getTopLeft(find.text('第一章')).dy <
          tester.getTopLeft(find.text('第三章')).dy,
      isTrue,
    );
  });

  testWidgets('写作设置：章节排序下拉可切换正序/倒序', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第一章'])]),
    ))!;
    final nbId = library.notebooks.first.id;
    await pumpSidebar(tester, library, settings, notebookId: nbId);

    await tester.tap(find.byTooltip('写作设置'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('章节排序'), findsOneWidget);
    expect(find.text('正序（旧章在上）'), findsOneWidget);

    await tester.tap(find.text('正序（旧章在上）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('倒序（新章在上）').last);
    await settle(tester);
    expect(settings.docsOrderFor(nbId), 'desc');
  });
}
