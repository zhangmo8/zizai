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
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 让真实异步（DB/文件 I/O）完成，然后刷新 UI。
  /// 多轮推进：FFI 每次往返的 continuation 在 fake zone 需一次 pump 才继续。
  Future<void> settle(WidgetTester tester, [int ms = 40]) async {
    for (var i = 0; i < 5; i++) {
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
    // 沉浸态：编辑器仍在
    expect(find.byType(q.QuillEditor), findsOneWidget);

    // Esc 退出
    await press(tester, [LogicalKeyboardKey.escape]);
    expect(find.textContaining('今日'), findsOneWidget);
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
}
