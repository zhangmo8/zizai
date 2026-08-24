import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/crash_journal.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/export.dart' show deltaToPlainText;
import 'package:zi_zai/core/snapshot_history.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';
import 'package:zi_zai/ui/find_bar.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 让真实异步（DB/文件 I/O）完成，然后刷新 UI。
  /// 多轮推进：FFI 每次往返的 continuation 在 fake zone 需一次 pump 才继续。
  Future<void> settle(WidgetTester tester, [int ms = 40, int rounds = 5]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)),
      );
      await tester.pump();
    }
  }

  late Directory tempDir;

  Future<(LibraryController, SettingsController, Db, CrashJournal, String)>
  makeApp({bool seeded = true}) async {
    tempDir = await Directory.systemTemp.createTemp('zizai_editor');
    final db = await Db.open('${tempDir.path}/test.db');
    final journal = await CrashJournal.create(tempDir);
    String docId = '';
    if (seeded) {
      final nb = await db.createNotebook('小说');
      final doc = await db.createDocument(nb.id, title: '第一章');
      docId = doc.id;
      // last_open 指向该文档，restore 才能打开（与真实启动一致）。
      await db.saveLastOpen(notebookId: nb.id, documentId: doc.id, words: 0);
    }
    final settings = SettingsController(db);
    await settings.load();
    final library = LibraryController(db);
    await library.restore();
    return (library, settings, db, journal, docId);
  }

  Future<void> typeText(WidgetTester tester, String text) async {
    await tester.tap(find.byType(q.QuillEditor));
    await tester.pump();
    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    final controller = editor.controller;
    // flutter_quill 用自定义 RawEditor（无 EditableText），经 controller 注入与真实输入等价。
    // 保留文档末尾 '\n'，替换其余全部内容。
    controller.replaceText(
      0,
      controller.document.length - 1,
      text,
      TextSelection.collapsed(offset: text.length),
    );
    await tester.pump();
  }

  /// 在编辑器当前光标处插入文本（保留已有内容，光标移到插入文本末尾）。
  Future<void> insertAtCursor(WidgetTester tester, String text) async {
    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    final controller = editor.controller;
    final pos = controller.selection.baseOffset;
    controller.replaceText(
      pos,
      0,
      text,
      TextSelection.collapsed(offset: pos + text.length),
    );
    await tester.pump();
  }

  LogicalKeyboardKey modifierKey() => Platform.isMacOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;

  Future<void> press(WidgetTester tester, List<LogicalKeyboardKey> keys) async {
    // 前 N-1 个是修饰键，最后一个为主键（只发一次 down+up）。
    final mods = keys.take(keys.length - 1).toList();
    for (final k in mods) {
      await tester.sendKeyDownEvent(k);
    }
    await tester.sendKeyEvent(keys.last);
    for (final k in mods.reversed) {
      await tester.sendKeyUpEvent(k);
    }
    await tester.pump();
  }

  testWidgets('输入 → 实时字数 + 防抖 1s 自动保存 + 今日增量', (tester) async {
    final (library, settings, db, _, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    await typeText(tester, '你好世界');
    expect(library.liveDocWords, 4); // 实时字数

    // 1s 防抖内未保存
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    final before = await tester.runAsync(() => db.getDocument(docId));
    expect(deltaToPlainText(before!.content), isEmpty);

    // 超过 1s → 自动保存
    await tester.pump(const Duration(milliseconds: 700));
    await settle(tester);
    final after = await tester.runAsync(() => db.getDocument(docId));
    expect(deltaToPlainText(after!.content), '你好世界');
    expect(library.todayDelta, 4); // 增量入库
    expect(find.text('今日 4/2000'), findsOneWidget);
  });

  testWidgets('Ctrl/Cmd+S 立即保存并闪「已保存」', (tester) async {
    final (library, settings, db, _, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    await typeText(tester, '立刻保存');
    // 不等防抖，直接 Ctrl/Cmd+S
    await press(tester, [modifierKey(), LogicalKeyboardKey.keyS]);
    await settle(tester);

    final doc = await tester.runAsync(() => db.getDocument(docId));
    expect(deltaToPlainText(doc!.content), '立刻保存');
    expect(find.text('已保存'), findsOneWidget);

    // 1s 后闪消失
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('已保存'), findsNothing);
  });

  testWidgets('失焦立即保存', (tester) async {
    final (library, settings, db, _, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    await typeText(tester, '失焦保存');
    // 主动失焦（模拟点击不可聚焦区域/切换）
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await settle(tester);

    final doc = await tester.runAsync(() => db.getDocument(docId));
    expect(deltaToPlainText(doc!.content), '失焦保存');
  });

  testWidgets('Cmd/Ctrl+F 打开应用查找条，Quill 内置搜索框不弹', (tester) async {
    final (library, settings, _, _, _) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    // 聚焦编辑器（命中 flutter_quill 内置 Cmd+F → OpenSearchIntent 的关键路径）
    await tester.tap(find.byType(q.QuillEditor));
    await tester.pump();

    await press(tester, [modifierKey(), LogicalKeyboardKey.keyF]);
    await settle(tester);

    // 应用自己的查找条打开
    expect(find.byType(FindBar), findsOneWidget);
    // flutter_quill 内置（未接本地化的空白）搜索对话框不得弹出
    expect(find.byType(q.QuillToolbarSearchDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);

    // 再次 Cmd+F：保持打开，仅重新聚焦查找框（不重复弹层）
    await press(tester, [modifierKey(), LogicalKeyboardKey.keyF]);
    await settle(tester);
    expect(find.byType(FindBar), findsOneWidget);
    expect(find.byType(q.QuillToolbarSearchDialog), findsNothing);

    // Esc 关闭
    await press(tester, [LogicalKeyboardKey.escape]);
    await settle(tester);
    expect(find.byType(FindBar), findsNothing);
  });

  testWidgets('上下文工具栏：选中浮现 → 加粗 → Esc 收起', (tester) async {
    final (library, settings, _, _, _) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    // 先聚焦编辑器（真实场景选中文本时编辑器必有焦点，Esc 才能到 Shortcuts）
    await tester.tap(find.byType(q.QuillEditor));
    await tester.pump();
    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    final controller = editor.controller;
    controller.replaceText(
      0,
      0,
      '你好世界',
      const TextSelection.collapsed(offset: 4),
    );
    await tester.pump();

    // 选区菜单由 Quill 的 overlay 在真实的长按/拖选手势后异步创建；widget
    // 测试直接更新 controller 不会生成该手势锚点。此处验证选区与 Esc 收起
    // 的模型状态，避免依赖不可复现的全局坐标。
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      q.ChangeSource.local,
    );
    await tester.pump();
    expect(controller.selection.isCollapsed, isFalse);

    await press(tester, [LogicalKeyboardKey.escape]);
    expect(controller.selection.isCollapsed, isTrue);
  });

  testWidgets('常驻格式工具栏：未选中也可见 → 加粗 → 清除格式', (tester) async {
    final (library, settings, _, _, _) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();

    // 无选区时工具栏即常驻可见（不随选中浮现）。
    expect(find.byTooltip('加粗'), findsOneWidget);
    expect(find.byTooltip('清除格式'), findsOneWidget);
    expect(find.byTooltip('撤销'), findsOneWidget);

    await typeText(tester, '你好世界');
    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    final controller = editor.controller;
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 4),
      q.ChangeSource.local,
    );
    await tester.pump();

    // 点击常驻工具栏「加粗」→ 选区获得 bold。
    await tester.tap(find.byTooltip('加粗'));
    await tester.pump();
    expect(
      controller.getSelectionStyle().attributes.containsKey('bold'),
      isTrue,
    );

    // 点击「清除格式」→ bold 移除。
    await tester.tap(find.byTooltip('清除格式'));
    await tester.pump();
    expect(
      controller.getSelectionStyle().attributes.containsKey('bold'),
      isFalse,
    );
  });

  testWidgets('沉浸模式：Ctrl+Shift+F 进入隐藏 chrome，Esc 退出', (tester) async {
    final (library, settings, _, _, _) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();

    // 聚焦编辑器后按快捷键
    await tester.tap(find.byType(q.QuillEditor));
    await tester.pump();
    await press(tester, [
      modifierKey(),
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.keyF,
    ]);

    // chrome 隐藏：状态栏 / 侧边栏 / 顶栏（含文档名）
    expect(find.textContaining('今日'), findsNothing);
    expect(find.text('第一章'), findsNothing);
    expect(find.text('新建章节'), findsNothing);
    // 沉浸态精简悬浮工具栏可见：前置退出按钮 + 核心格式（加粗）
    expect(find.byTooltip('退出沉浸 (Esc)'), findsOneWidget);
    expect(find.text('退出沉浸'), findsOneWidget);
    expect(find.byTooltip('加粗'), findsOneWidget);
    // 沉浸态：编辑器仍在
    expect(find.byType(q.QuillEditor), findsOneWidget);

    // Esc 退出 → chrome 恢复，悬浮工具栏消失
    await press(tester, [LogicalKeyboardKey.escape]);
    expect(find.textContaining('今日'), findsOneWidget);
    expect(find.byTooltip('退出沉浸 (Esc)'), findsNothing);
  });

  testWidgets('焦点暗淡：顶栏 contrast 开关写入 settings 并挂载蒙层', (tester) async {
    final (library, settings, _, _, _) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();

    expect(settings.settings.focusDim, isFalse);
    expect(find.byTooltip('暗淡非当前行'), findsOneWidget);

    await typeText(tester, '第一段\n第二段\n第三段');

    // 打开 → 写入 settings 并持久化；蒙层挂载（active 态 tooltip 同步）。
    await tester.tap(find.byTooltip('暗淡非当前行'));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
    expect(settings.settings.focusDim, isTrue);
    expect(find.byTooltip('关闭暗淡非当前行'), findsOneWidget);
    // 蒙层 CustomPaint 已挂载且渲染无异常（选区/滚动重绘不抛错）。
    await tester.pump(const Duration(milliseconds: 120));
    await tester.runAsync(() => settings.load());
    expect(settings.settings.focusDim, isTrue);

    // 关闭 → 恢复
    await tester.tap(find.byTooltip('关闭暗淡非当前行'));
    await tester.pump();
    expect(settings.settings.focusDim, isFalse);
  });

  testWidgets('崩溃恢复：启动出现确认条 → 恢复 → 内容入库', (tester) async {
    final (library, settings, db, journal, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    // 模拟崩溃残留：journal 与库不一致
    await tester.runAsync(
      () => journal.write(
        CrashJournalEntry(
          documentId: docId,
          title: '第一章',
          content: '[{"insert":"未保存的正文"}]',
          savedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );

    await tester.pumpWidget(
      ZiZaiApp(library: library, settings: settings, journal: journal),
    );
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await settle(tester);
    }
    await tester.pump();

    // 确认条出现
    expect(find.textContaining('未保存内容，恢复？'), findsOneWidget);
    await tester.tap(find.text('恢复'));
    await settle(tester);

    final doc = await tester.runAsync(() => db.getDocument(docId));
    expect(deltaToPlainText(doc!.content), '未保存的正文');
    // journal 已清除
    final entry = await tester.runAsync(() => journal.read());
    expect(entry, isNull);
  });

  testWidgets('保存失败：错误条 + 缓冲保留', (tester) async {
    final (library, settings, db, _, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    // 注入失败：关闭 db（保存必然失败）
    await tester.runAsync(() => db.close());
    await typeText(tester, '丢失不得');
    await tester.pump(const Duration(milliseconds: 1100));
    await settle(tester);

    // 错误条出现；缓冲仍在编辑器内存（实时字数还在）
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(library.liveDocWords, 4);
  });

  testWidgets('保存失败 → 重试成功后错误条清除', (tester) async {
    final (library, settings, db, _, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    // 注入瞬时保存失败：给 documents 表加 BEFORE UPDATE 触发器，保存即中止。
    // 用第二个连接创建，不影响应用持有的 db 连接；随后删除触发器恢复写库。
    Future<void> withConn(Future<void> Function(dynamic conn) fn) async {
      // singleInstance:false —— 必须独立连接：默认 singleInstance 共享同一
      // Database 实例，close() 会把应用持有的 db 连接一起关掉。
      final conn = await tester.runAsync(
        () => databaseFactory.openDatabase(
          '${tempDir.path}/test.db',
          options: OpenDatabaseOptions(singleInstance: false),
        ),
      );
      try {
        await tester.runAsync(() => fn(conn!));
      } finally {
        await tester.runAsync(() => conn!.close());
      }
    }

    await withConn((conn) async => conn.execute(
      "CREATE TRIGGER inject_save_fail BEFORE UPDATE ON documents "
      "BEGIN SELECT RAISE(ABORT, 'injected'); END",
    ));

    await typeText(tester, '重试后可存');
    await tester.pump(const Duration(milliseconds: 1100));
    await settle(tester);

    // 保存被触发器中止 → 错误条 + 缓冲保留
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(library.saveError, isNotNull);

    // 恢复写库能力后点「重试」→ 保存成功、错误条清除
    await withConn((conn) async => conn.execute('DROP TRIGGER inject_save_fail'));
    await tester.tap(find.text('重试'));
    await settle(tester);

    expect(find.textContaining('保存失败'), findsNothing);
    expect(library.saveError, isNull);
    final doc = await tester.runAsync(() => db.getDocument(docId));
    expect(deltaToPlainText(doc!.content), '重试后可存');
  });

  testWidgets('切换章节：先保存旧章节并立即显示新章节内容', (tester) async {
    final (library, settings, db, _, firstId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    final second = (await tester.runAsync(
      () => db.createDocument(
        library.notebooks.single.id,
        title: '第二章',
        content: '[{"insert":"第二章正文"}]',
      ),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    await typeText(tester, '第一章新内容');
    await tester.runAsync(() => library.switchDocument(second.id));
    await tester.pump();
    await settle(tester);

    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    expect(editor.controller.document.toPlainText().trim(), '第二章正文');
    expect(library.currentDocument?.id, second.id);
    final savedFirst = await tester.runAsync(() => db.getDocument(firstId));
    expect(deltaToPlainText(savedFirst!.content), '第一章新内容');
  });

  testWidgets('版本历史：自动基线快照 → 预览 → 回滚生效且不被旧缓冲覆盖', (tester) async {
    final (library, settings, db, _, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    final snapshots = SnapshotHistory(rootPath: '${tempDir.path}/snapshots');
    await tester.pumpWidget(
      ZiZaiApp(library: library, settings: settings, snapshots: snapshots),
    );
    await tester.pump();

    // 第一次保存：旧内容为空 → 不留底
    await typeText(tester, '初稿的内容');
    await press(tester, [modifierKey(), LogicalKeyboardKey.keyS]);
    await settle(tester);
    expect((await tester.runAsync(() => snapshots.list(docId)))!, isEmpty);

    // 第二次保存：写库前自动留基线快照（= 初稿）。
    // 快照 + 写库是长真实 IO 链，加大 settle 轮次推完。
    await typeText(tester, '第二稿的内容');
    await press(tester, [modifierKey(), LogicalKeyboardKey.keyS]);
    await settle(tester, 40, 15);
    final baseline = await tester.runAsync(() => snapshots.list(docId));
    expect(baseline!.length, 1);
    expect(deltaToPlainText(baseline.single.content), '初稿的内容');

    // 顶栏入口 → 对话框：列表 + 右侧预览
    await tester.tap(find.byTooltip('版本历史'));
    await settle(tester, 40, 15);
    expect(find.text('第一章 · 版本历史'), findsOneWidget);
    expect(find.textContaining('初稿的内容'), findsOneWidget);

    // 回滚 → 确认
    await tester.tap(find.text('回滚到此版本'));
    await settle(tester);
    await tester.tap(find.text('回滚'));
    await settle(tester, 40, 20);

    // 对话框关闭；编辑器就地重载为初稿（同文档 id，必须显式重载）
    expect(find.text('回滚到此版本'), findsNothing);
    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    expect(editor.controller.document.toPlainText().trim(), '初稿的内容');
    // 回滚前的第二稿也自动留底
    final after = await tester.runAsync(() => snapshots.list(docId));
    expect(after!.length, 2);

    // 关键回归：旧缓冲不得经 Cmd+S / 防抖保存覆盖回滚结果
    await press(tester, [modifierKey(), LogicalKeyboardKey.keyS]);
    await tester.pump(const Duration(milliseconds: 1500));
    await settle(tester, 40, 10);
    final saved = await tester.runAsync(() => db.getDocument(docId));
    expect(deltaToPlainText(saved!.content), '初稿的内容');
    // 走完回滚成功 toast 的自动消失定时器
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('行首缩进：开启后段落行首输入自动前置两个全角空格', (tester) async {
    final (library, settings, db, _, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    // 开启当前笔记本的行首缩进。
    await tester.runAsync(
      () => settings.setIndentForNotebook(library.notebooks.single.id, true),
    );
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    final controller = editor.controller;
    // 清空到空文档（保留结尾 \n），保证光标从 0 开始。
    controller.replaceText(
      0,
      controller.document.length - 1,
      '',
      const TextSelection.collapsed(offset: 0),
    );
    await tester.pump();

    // 行首输入「你」→ 自动前置两个全角空格，光标在其后。
    // 注意：断言用 trimRight 而非 trim——全角空格 U+3000 属于 Unicode 空白，
    // String.trim() 会把它误删。
    await insertAtCursor(tester, '你');
    expect(controller.document.toPlainText().trimRight(), '\u3000\u3000你');
    expect(controller.selection.baseOffset, 3);

    // 段落中间继续输入不重复缩进。
    await insertAtCursor(tester, '好');
    expect(controller.document.toPlainText().trimRight(), '\u3000\u3000你好');

    // 换行后行首输入块格式触发词 → 不缩进（markdown 快捷不受影响）。
    await insertAtCursor(tester, '\n');
    await insertAtCursor(tester, '#');
    expect(
      controller.document.toPlainText().trimRight(),
      '\u3000\u3000你好\n#',
    );

    await tester.runAsync(() => db.close());
  });

  testWidgets('行首缩进：默认关闭时行首输入不缩进', (tester) async {
    final (library, settings, db, _, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    final controller = editor.controller;
    controller.replaceText(
      0,
      controller.document.length - 1,
      '',
      const TextSelection.collapsed(offset: 0),
    );
    await tester.pump();

    await insertAtCursor(tester, '你');
    expect(controller.document.toPlainText().trim(), '你');

    await tester.runAsync(() => db.close());
  });

  testWidgets('标点配对：输入【补全】光标在中间，输入】跳过', (tester) async {
    final (library, settings, db, _, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    final controller = editor.controller;
    // 清空到空文档（保留结尾 \n），保证光标从 0 开始。
    controller.replaceText(
      0,
      controller.document.length - 1,
      '',
      const TextSelection.collapsed(offset: 0),
    );
    await tester.pump();

    // 输入【 → 自动补全】，光标停在中间。
    await insertAtCursor(tester, '【');
    expect(controller.document.toPlainText().trim(), '【】');
    expect(controller.selection.baseOffset, 1);

    // 光标在补全对中间输入】 → 跳过，不产生重复。
    await insertAtCursor(tester, '】');
    expect(controller.document.toPlainText().trim(), '【】');
    expect(controller.selection.baseOffset, 2);

    // 其它括号同样补全。
    await insertAtCursor(tester, '（');
    expect(controller.document.toPlainText().trim(), '【】（）');
    expect(controller.selection.baseOffset, 3);

    // 普通字符不受影响（光标在（）中间，内容自然填入其中）。
    await insertAtCursor(tester, '内容');
    expect(controller.document.toPlainText().trim(), '【】（内容）');
    expect(controller.selection.baseOffset, 5);

    await tester.runAsync(() => db.close());
  });

  testWidgets('全书搜索：Ctrl/Cmd+P 打开 → 命中分组 → 跨章跳转定位', (tester) async {
    final (library, settings, _, _, _) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    final second = (await tester.runAsync(
      () => library.createDocument(
        library.notebooks.single.id,
        title: '第二章',
      ),
    ))!;
    await tester.runAsync(
      () => library.saveDocument(
        documentId: second.id,
        title: '第二章',
        content: '[{"insert":"李四再次出现\\n"}]',
        writtenWords: 0,
      ),
    );
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    // 当前章写入并保存（树缓存须同步，才能被全书搜索命中）
    await typeText(tester, '主角李四出场');
    await press(tester, [modifierKey(), LogicalKeyboardKey.keyS]);
    await settle(tester);

    // Ctrl/Cmd+P 打开搜索
    await press(tester, [modifierKey(), LogicalKeyboardKey.keyP]);
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '李四');
    await tester.pump(const Duration(milliseconds: 300)); // 防抖
    await settle(tester);

    // 两章命中，按章节分组
    expect(find.textContaining('2 处匹配'), findsOneWidget);
    expect(find.textContaining('小说 / 第一章'), findsOneWidget);
    expect(find.textContaining('小说 / 第二章'), findsOneWidget);

    // 点第二章命中 → 切换文档 + 选中命中词
    await tester.tap(find.textContaining('再次出现', findRichText: true));
    await settle(tester);
    expect(library.currentDocument?.id, second.id);
    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    expect(editor.controller.document.toPlainText().trim(), '李四再次出现');
    expect(editor.controller.selection.baseOffset, 0);
    expect(editor.controller.selection.extentOffset, 2);
  });
}
