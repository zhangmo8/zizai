/// 编辑器块级交互测试：Markdown 快捷语法（行首触发词+空格）、
/// 斜杠命令菜单（/ 唤起 → 键盘导航 → 应用块格式）、顶栏标题改名。
library;

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

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> settle(WidgetTester tester, [int ms = 40]) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: ms)),
      );
      await tester.pump();
    }
  }

  late Directory tempDir;

  Future<(LibraryController, SettingsController, Db, String)> makeApp() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_blocks');
    final db = await Db.open('${tempDir.path}/test.db');
    final nb = await db.createNotebook('小说');
    final doc = await db.createDocument(nb.id, title: '第一章');
    await db.saveLastOpen(notebookId: nb.id, documentId: doc.id, words: 0);
    final settings = SettingsController(db);
    await settings.load();
    final library = LibraryController(db);
    await library.restore();
    // 测试编辑器需要处于工作区：启动停在书架，这里恢复进书。
    await library.openNotebook(nb.id);
    return (library, settings, db, doc.id);
  }

  Future<q.QuillController> focusEditor(WidgetTester tester) async {
    await tester.tap(find.byType(q.QuillEditor));
    await tester.pump();
    final editor = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
    return editor.controller;
  }

  testWidgets('Markdown 快捷：行首 “#”+空格 → H1，触发词被移除', (tester) async {
    final (library, settings, _, _) = (await tester.runAsync(() => makeApp()))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    final controller = await focusEditor(tester);
    controller.replaceText(0, 0, '#', const TextSelection.collapsed(offset: 1));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    // 触发词已被消费，行变为 H1 空标题行。
    expect(controller.document.toPlainText(), '\n');
    final lineStyle = controller.getSelectionStyle().attributes;
    expect(lineStyle['header']?.value, 1);
  });

  testWidgets('Markdown 快捷：行首 “>”+空格 → 引用块', (tester) async {
    final (library, settings, _, _) = (await tester.runAsync(() => makeApp()))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    final controller = await focusEditor(tester);
    controller.replaceText(0, 0, '>', const TextSelection.collapsed(offset: 1));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(controller.document.toPlainText(), '\n');
    expect(controller.getSelectionStyle().attributes['blockquote'], isNotNull);
  });

  testWidgets('斜杠菜单：输入 / 弹出 → ↓ + Enter 应用「标题 1」', (tester) async {
    final (library, settings, _, _) = (await tester.runAsync(() => makeApp()))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    final controller = await focusEditor(tester);
    controller.replaceText(0, 0, '/', const TextSelection.collapsed(offset: 1));
    await tester.pump();
    await tester.pump(); // overlay 定位（post-frame）

    // 菜单出现（含全部命令）
    expect(find.text('转换为'), findsOneWidget);
    expect(find.text('标题 1'), findsOneWidget);
    expect(find.text('待办清单'), findsOneWidget);

    // ↓ 选中「标题 1」（索引 1；索引 0 为正文），Enter 应用
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    // 菜单关闭；“/” 已删除；当前行为 H1
    expect(find.text('转换为'), findsNothing);
    expect(controller.document.toPlainText(), '\n');
    expect(controller.getSelectionStyle().attributes['header']?.value, 1);
  });

  testWidgets('斜杠菜单：继续输入过滤，Esc 关闭且不动正文', (tester) async {
    final (library, settings, _, _) = (await tester.runAsync(() => makeApp()))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    await tester.pump();

    final controller = await focusEditor(tester);
    controller.replaceText(0, 0, '/', const TextSelection.collapsed(offset: 1));
    await tester.pump();
    await tester.pump();
    expect(find.text('转换为'), findsOneWidget);

    // 追加过滤词 todo → 仅剩「待办清单」
    controller.replaceText(
      1,
      0,
      'todo',
      const TextSelection.collapsed(offset: 5),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('待办清单'), findsOneWidget);
    expect(find.text('标题 1'), findsNothing);

    // Esc 只收起菜单，文本保留
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('转换为'), findsNothing);
    expect(controller.document.toPlainText(), '/todo\n');
  });

  testWidgets('顶栏标题：点击后编辑改名入库并同步侧栏', (tester) async {
    final (library, settings, db, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();

    // 正文区域不再渲染大标题；顶栏标题点击后才出现紧凑输入框。
    expect(find.widgetWithText(TextField, '第一章'), findsNothing);
    await tester.tap(find.byTooltip('编辑标题'));
    await tester.pump();
    final titleField = find.widgetWithText(TextField, '第一章');
    expect(titleField, findsOneWidget);

    await tester.enterText(titleField, '序章');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    final doc = await tester.runAsync(() => db.getDocument(docId));
    expect(doc!.title, '序章');
    // 侧栏树行同步显示新名
    expect(find.text('序章'), findsWidgets);
  });

  testWidgets('顶栏标题：拒绝同笔记本内的重复标题', (tester) async {
    final (library, settings, db, docId) = (await tester.runAsync(
      () => makeApp(),
    ))!;
    await tester.runAsync(
      () => library.createDocument(library.notebooks.single.id, title: '已存在章节'),
    );
    await tester.pumpWidget(ZiZaiApp(library: library, settings: settings));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();

    await tester.tap(find.byTooltip('编辑标题'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, '第一章'), '已存在章节');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(find.text('同名章节已存在'), findsOneWidget);
    final doc = await tester.runAsync(() => db.getDocument(docId));
    expect(doc!.title, '第一章');
    await tester.pump(const Duration(seconds: 3));
  });
}
