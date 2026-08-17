import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/export.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/ui/export_dialog.dart';
import 'package:zi_zai/ui/zz.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> settle(WidgetTester tester, [int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
    }
  }

  Future<LibraryController> makeLibrary() async {
    final tempDir = await Directory.systemTemp.createTemp('zizai_export');
    final db = await Db.open('${tempDir.path}/test.db');
    final nb = await db.createNotebook('我的书');
    await db.createDocument(
      nb.id,
      title: '开端',
      content: '[{"insert":"第一段\\n第二段\\n"}]',
    );
    await db.createDocument(nb.id, title: '发展', content: '[{"insert":"正文\\n"}]');
    final library = LibraryController(db);
    await library.restore();
    return library;
  }

  Future<void> pumpDialog(
    WidgetTester tester,
    LibraryController library, {
    SaveBookTextHandler? saveText,
    SaveBookFilesHandler? saveFiles,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Material(
            child: Center(
              child: TextButton(
                onPressed: () => showBookExportDialog(
                  context,
                  library: library,
                  saveText: saveText,
                  saveFiles: saveFiles,
                ),
                child: const Text('打开导出'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开导出'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('默认 TXT：章节编号 + 段首缩进 + 段间空行 → 注入 handler 收到产物', (tester) async {
    final library = (await tester.runAsync(makeLibrary))!;
    String? savedName;
    String? savedText;
    await pumpDialog(
      tester,
      library,
      saveText: (name, text) async {
        savedName = name;
        savedText = text;
        return true;
      },
    );
    expect(find.text('导出整本书'), findsOneWidget);

    await tester.tap(find.widgetWithText(ZzButton, '导出'));
    await settle(tester);

    expect(savedName, '我的书.txt');
    expect(savedText, contains('第 1 章 开端'));
    expect(savedText, contains('第 2 章 发展'));
    expect(savedText, contains('　　第一段\n\n　　第二段'));
    // 完成后对话框关闭 + toast
    expect(find.text('导出整本书'), findsNothing);
    expect(find.text('已导出 2 章'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // toast 定时器走完
  });

  testWidgets('切换为每章一个 Markdown 文件 → 文件名带序号', (tester) async {
    final library = (await tester.runAsync(makeLibrary))!;
    List<BookExportFile>? saved;
    await pumpDialog(
      tester,
      library,
      saveFiles: (files) async {
        saved = files;
        return true;
      },
    );

    await tester.tap(find.text('TXT 单文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Markdown · 每章一个文件'));
    await tester.pumpAndSettle();
    // Markdown 格式下 TXT 专属排版选项隐藏
    expect(find.text('段首缩进'), findsNothing);

    await tester.tap(find.widgetWithText(ZzButton, '导出'));
    await settle(tester);

    expect(saved, isNotNull);
    expect(saved!.length, 2);
    expect(saved![0].fileName, '001 第 1 章 开端.md');
    expect(saved![0].content, startsWith('# 第 1 章 开端'));
    expect(saved![1].fileName, '002 第 2 章 发展.md');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('handler 返回 false（用户取消）→ 对话框保持打开', (tester) async {
    final library = (await tester.runAsync(makeLibrary))!;
    await pumpDialog(tester, library, saveText: (_, _) async => false);

    await tester.tap(find.widgetWithText(ZzButton, '导出'));
    await settle(tester);

    expect(find.text('导出整本书'), findsOneWidget);
    expect(find.text('已导出 2 章'), findsNothing);
  });
}
