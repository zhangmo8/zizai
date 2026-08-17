import 'dart:io';

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
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

    final secondNotebookTop = tester.getTopLeft(find.text('随笔')).dy;
    await tester.tap(find.text('新建章节').first);
    await tester.pump();
    expect(tester.getTopLeft(find.text('随笔')).dy, secondNotebookTop);
  });

  testWidgets('新建章节：默认名行内重命名', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(tree: [('小说', [])]),
    ))!;
    await pumpSidebar(tester, library);

    await tester.tap(find.text('新建章节'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '01-开端.md');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(find.text('01-开端.md'), findsOneWidget);
  });

  testWidgets('新建章节：可用取消按钮退出且不创建文档', (tester) async {
    final (library, _) = (await tester.runAsync(
      () => makeApp(tree: [('小说', [])]),
    ))!;
    await pumpSidebar(tester, library);

    await tester.tap(find.text('新建章节'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '临时章节');
    await tester.tap(find.byTooltip('取消编辑'));
    await tester.pump();

    final notebookId = library.notebooks.single.id;
    expect(library.documentsOf(notebookId), isEmpty);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('新建章节'), findsOneWidget);
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
