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
import 'package:zi_zai/ui/sidebar.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 让真实异步（DB I/O）完成，然后刷新 UI。
  /// 多轮推进：FFI 每次往返的 continuation 在 fake zone 需一次 pump 才继续。
  Future<void> settle(WidgetTester tester) async {
    // 写库是真实异步（sqflite_common_ffi），慢 CI 上需要更多真实时间窗口。
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
    // 用唯一临时文件库（inMemoryDatabasePath 会被 sqflite 按路径缓存，测试间共享）。
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

  Future<void> pumpSidebar(
    WidgetTester tester,
    LibraryController library,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 800,
            child: Sidebar(library: library),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 打开第 [index] 个行菜单（0 起；笔记本行在前，文档行在后）。
  /// 桌面端菜单 hover 行才浮现：先悬停到菜单位置触发显隐。
  Future<void> openRowMenu(WidgetTester tester, int index) async {
    final menu = find.byIcon(Icons.more_horiz).at(index);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.moveTo(tester.getCenter(menu));
    await tester.pump();
    await tester.tap(menu);
    await tester.pumpAndSettle(); // 菜单完全展开后再点菜单项
    await gesture.removePointer();
  }

  /// 点击菜单项并提交行内编辑。
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

    test('全部阿拉伯编号 → 递增', () {
      expect(
        suggestedChapterTitle([doc('第 1 章'), doc('第 2 章')]),
        '第 3 章',
      );
    });

    test('混入自定义名 → 新章节', () {
      expect(
        suggestedChapterTitle([doc('第 1 章'), doc('序章')]),
        '新章节',
      );
    });

    test('中文编号 → 中文递增', () {
      expect(
        suggestedChapterTitle([doc('第一章'), doc('第二章')]),
        '第三章',
      );
    });

    test('非连续编号 → 取最大值 +1', () {
      expect(
        suggestedChapterTitle([doc('第 1 章'), doc('第 5 章')]),
        '第 6 章',
      );
    });
  });

  group('reorderTarget 拖拽落点映射', () {
    TreeRowRef nb(String id) => TreeRowRef(notebookId: id, isHeader: true);
    TreeRowRef doc(String nbId, String docId) =>
        TreeRowRef(notebookId: nbId, docId: docId);
    TreeRowRef btn(String nbId) => TreeRowRef(notebookId: nbId);

    // 树：小说[一,二] + 随笔[] → 行：nb小说, 一, 二, new小说, nb随笔, new随笔
    final refs = [nb('A'), doc('A', 'd1'), doc('A', 'd2'), btn('A'), nb('B'), btn('B')];

    test('同笔记本下移一位', () {
      expect(reorderTarget(refs, 1, 2), ('A', 1));
    });

    test('同笔记本落点未变 → null（不写库）', () {
      expect(reorderTarget(refs, 1, 1), isNull);
    });

    test('拖到下一笔记本头前 = 当前笔记本末尾', () {
      expect(reorderTarget(refs, 1, 3), ('A', 1));
    });

    test('跨笔记本移动到空笔记本开头', () {
      expect(reorderTarget(refs, 1, 4), ('B', 0));
    });

    test('跨笔记本移动到列表末尾', () {
      expect(reorderTarget(refs, 1, refs.length), ('B', 0));
    });

    test('跨笔记本移动到非空笔记本中间', () {
      final refs2 = [
        nb('A'),
        doc('A', 'd1'),
        btn('A'),
        nb('B'),
        doc('B', 'e1'),
        doc('B', 'e2'),
        btn('B'),
      ];
      // 把 A 的 d1 拖到 B 的 e1、e2 之间（插入到 e2 前，即 remaining 索引 4）。
      expect(reorderTarget(refs2, 1, 4), ('B', 1));
    });

    test('拖到笔记本头前 = 上一笔记本末尾', () {
      final refs3 = [
        nb('A'),
        doc('A', 'd1'),
        doc('A', 'd2'),
        btn('A'),
        nb('B'),
        doc('B', 'e1'),
        btn('B'),
      ];
      // 把 B 的 e1 拖到 nbB 头前（插入到 nbB 头，即 remaining 索引 4）。
      expect(reorderTarget(refs3, 5, 4), ('A', 2));
    });

    test('非文档行（笔记本头/新建按钮）不可拖', () {
      expect(reorderTarget(refs, 0, 1), isNull);
      expect(reorderTarget(refs, 3, 1), isNull);
    });
  });

  testWidgets('拖拽排序：拖手柄同笔记本内重排', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章']),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);
    final nbId = library.notebooks.first.id;
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);

    // 桌面端手柄 hover 行才浮现：先悬停 → 等 _HoverReveal 淡入 → 按下拖拽。
    final grip = find.byIcon(Icons.drag_indicator).first;
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.moveTo(tester.getCenter(grip));
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.down(tester.getCenter(grip));
    await tester.pump();
    // 下移一行（行高 30 + 上下 margin 各 1 = 32）：分步移动让 gap 动画追上手势。
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

  testWidgets('拖拽排序：跨笔记本移动章节', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章']),
          ('随笔集', []),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);
    final aId = library.notebooks[0].id;
    final bId = library.notebooks[1].id;

    // 第一章的手柄拖到 随笔集 分区内（空笔记本，落点映射为位置 0）。
    final grip = find.byIcon(Icons.drag_indicator).first;
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.moveTo(tester.getCenter(grip));
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.down(tester.getCenter(grip));
    await tester.pump();
    // 共下移 96px（≈3 行）：越过 小说 分区与 随笔集 笔记本头，落到分区内。
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, 24));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    await gesture.removePointer();
    await settle(tester);

    expect(library.documentsOf(aId).map((d) => d.title), isEmpty);
    expect(library.documentsOf(bId).map((d) => d.title), ['第一章']);
  });

  testWidgets('点击兼容：行体带轻微移动仍切换文档（不触发拖拽）', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章']),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);
    final nbId = library.notebooks.first.id;

    // 模拟鼠标抖动：按下后移动 3px（仍超出拖拽 slop 之外的常规点击）。
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
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章']),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);
    final nbId = library.notebooks.first.id;
    expect(library.currentDocument, isNull);

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

    expect(library.currentDocument, isNull);
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);
  });

  testWidgets('树渲染：笔记本展开 + 文档 + 当前文档高亮', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章']),
          ('随笔集', []),
        ],
      ),
    ))!;
    // 确定当前文档
    await tester.runAsync(
      () => library.switchDocument(
        library.documentsOf(library.notebooks.first.id).first.id,
      ),
    );
    await pumpSidebar(tester, library);

    expect(find.text('小说'), findsOneWidget);
    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('第二章'), findsOneWidget);
    expect(find.text('随笔集'), findsOneWidget);
    expect(find.text('新建章节'), findsNWidgets(2)); // 两个笔记本各一个
  });

  testWidgets('笔记本行：标题后显示章节总数（空笔记本不显示）', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章', '第三章']),
          ('随笔集', []),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);

    expect(find.text('3章'), findsOneWidget);
    expect(find.text('0章'), findsNothing); // 空笔记本保持安静
  });

  testWidgets('空态：按钮 → 行内输入 → Enter 创建笔记本', (tester) async {
    final (library, _) = (await tester.runAsync(() => makeApp()))!;
    await pumpSidebar(tester, library);

    expect(find.text('新建一本笔记本，开始写'), findsOneWidget);
    await tester.tap(find.text('新建笔记本'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '我的小说');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(find.text('我的小说'), findsOneWidget);
    expect(find.text('新建一本笔记本，开始写'), findsNothing);
  });

  testWidgets('顶栏 + 新建笔记本（默认名）', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(tree: [('旧本', [])]),
    ))!;
    await pumpSidebar(tester, library);

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('写作空间'), findsNothing);

    await tester.tap(find.byTooltip('新建笔记本'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done); // 默认名「新笔记本」
    await settle(tester);
    expect(find.text('新笔记本'), findsOneWidget);
  });

  testWidgets('笔记本和章节进入行内编辑时保持后续行位置稳定', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章']),
          ('随笔', []),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);

    final secondChapterTop = tester.getTopLeft(find.text('第二章')).dy;
    await openRowMenu(tester, 1);
    await tester.tap(find.text('重命名'));
    await tester.pump();
    expect(tester.getTopLeft(find.text('第二章')).dy, secondChapterTop);
    await tester.tap(find.byTooltip('取消编辑'));
    await tester.pump();
  });

  testWidgets('新建章节：点击 + 直接生成，自动编号（不进入命名）', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(tree: [('小说', ['第 1 章', '第 2 章', '第 3 章'])]),
    ))!;
    await pumpSidebar(tester, library);
    final nbId = library.notebooks.first.id;

    await tester.tap(find.text('新建章节').first);
    await settle(tester);

    // 顺着已有章节自动编号：已有 3 章 → 第 4 章；无命名环节。
    expect(
      library.documentsOf(nbId).map((d) => d.title),
      ['第 1 章', '第 2 章', '第 3 章', '第 4 章'],
    );
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('新建章节：空笔记本点击 + → 直接生成「第 1 章」', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(tree: [('小说', [])]),
    ))!;
    await pumpSidebar(tester, library);
    final nbId = library.notebooks.first.id;

    await tester.tap(find.text('新建章节'));
    await settle(tester);

    expect(library.documentsOf(nbId).map((d) => d.title), ['第 1 章']);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('重命名文档：⋮ → 重命名 → Enter', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章']),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);

    await openRowMenu(tester, 1); // 第 1 个 ⋮ 是笔记本行，第 2 个是文档行
    await renameViaMenu(tester, '新标题');
    await settle(tester);

    expect(find.text('新标题'), findsOneWidget);
    expect(find.text('第一章'), findsNothing);
  });

  testWidgets('重名冲突：错误态不允许提交', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章']),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);

    await openRowMenu(tester, 2); // 第二章
    await renameViaMenu(tester, '第一章');
    expect(find.text('同名已存在'), findsOneWidget);
    await settle(tester);
    // 名称未变（编辑框顶替了行渲染，断言以 controller 为准）
    final nbId = library.notebooks.first.id;
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);
  });

  testWidgets('非法文件名（含 /）错误态', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章']),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);

    await openRowMenu(tester, 1);
    await renameViaMenu(tester, 'a/b');
    expect(find.text('名称不能包含 / 或 \\'), findsOneWidget);
  });

  testWidgets('Esc 取消编辑，不产生变更', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章']),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);

    await openRowMenu(tester, 1);
    await tester.tap(find.text('重命名'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '临时');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('第一章'), findsOneWidget);
  });

  testWidgets('文档上移/下移', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章']),
        ],
      ),
    ))!;
    await pumpSidebar(tester, library);
    final nbId = library.notebooks.first.id;
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);

    // 第二章上移
    await openRowMenu(tester, 2);
    await tester.tap(find.text('上移'));
    await settle(tester);
    expect(library.documentsOf(nbId).map((d) => d.title), ['第二章', '第一章']);

    // 第二章下移（当前在前）→ 回到原序
    await openRowMenu(tester, 1);
    await tester.tap(find.text('下移'));
    await settle(tester);
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章', '第二章']);
  });

  testWidgets('单击文档切换当前文档，先触发 beforeSwitchSave', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章']),
        ],
      ),
    ))!;
    var saved = false;
    library.beforeSwitchSave = () async {
      saved = true;
    };
    await pumpSidebar(tester, library);

    await tester.tap(find.text('第二章'));
    await settle(tester);
    expect(saved, isTrue);
    expect(library.currentDocument?.title, '第二章');
  });

  testWidgets('删除文档：确认条出现 → 确认后移除', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章']),
        ],
      ),
    ))!;
    // 用完整 Shell 渲染确认条（编辑器区顶部）
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();

    await openRowMenu(tester, 2); // 第二章
    await tester.tap(find.text('删除'));
    await tester.pump();

    expect(find.textContaining('删除《第二章》'), findsOneWidget);
    await tester.tap(find.text('确认删除'));
    await settle(tester);
    final nbId = library.notebooks.first.id;
    expect(library.documentsOf(nbId).map((d) => d.title), ['第一章']);
  });

  testWidgets('删除取消：5s 无操作自动关闭（不删除）', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章']),
        ],
      ),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();

    await openRowMenu(tester, 1);
    await tester.tap(find.text('删除'));
    await tester.pump();
    expect(find.textContaining('此操作不可恢复'), findsOneWidget);

    // 5s 后自动关闭
    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining('此操作不可恢复'), findsNothing);
    expect(library.pendingDeletion, isNull);
    final nbId = library.notebooks.first.id;
    expect(library.documentsOf(nbId), hasLength(1));
  });

  testWidgets('删除笔记本：确认后级联删除其下全部章节', (tester) async {
    final (library, settings) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章', '第二章']),
        ],
      ),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();

    await openRowMenu(tester, 0); // 笔记本行
    await tester.tap(find.text('删除'));
    await tester.pump();

    expect(find.textContaining('删除《小说》'), findsOneWidget);
    await tester.tap(find.text('确认删除'));
    await settle(tester);

    // 笔记本与全部章节一起从树中移除（级联删除）
    expect(library.notebooks, isEmpty);
    expect(library.allDocuments, isEmpty);
    expect(find.text('第一章'), findsNothing);
    expect(find.text('第二章'), findsNothing);
  });

  testWidgets('全书搜索入口：接线时顶栏出现按钮，点击触发回调', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(
        tree: [
          ('小说', ['第一章']),
        ],
      ),
    ))!;
    // 未接线：无搜索按钮（既有 pumpSidebar 路径）
    await pumpSidebar(tester, library);
    expect(find.byIcon(Icons.search), findsNothing);

    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 800,
            child: Sidebar(
              library: library,
              onOpenBookSearch: () => opened++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final button = find.byIcon(Icons.search);
    expect(button, findsOneWidget);
    await tester.tap(button);
    expect(opened, 1);
  });
}
