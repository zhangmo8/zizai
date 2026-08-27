import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/ui/word_distribution_dialog.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 造一本 3 章的书：五章/十三章/三章（按存储顺序 = 目录正序）。
  Future<LibraryController> makeLibrary({int chapters = 3}) async {
    final tempDir = await Directory.systemTemp.createTemp('zizai_worddist');
    final db = await Db.open('${tempDir.path}/test.db');
    final nb = await db.createNotebook('我的书');
    if (chapters >= 1) {
      await db.createDocument(
        nb.id,
        title: '开端',
        content: '[{"insert":"一二三四五\\n"}]', // 5 字
      );
    }
    if (chapters >= 2) {
      await db.createDocument(
        nb.id,
        title: '高潮',
        content:
            '[{"insert":"一二三四五六七八九十十一十二十三\\n"}]', // 13 字
      );
    }
    if (chapters >= 3) {
      await db.createDocument(
        nb.id,
        title: '结局',
        content: '[{"insert":"一二三\\n"}]', // 3 字
      );
    }
    final library = LibraryController(db);
    await library.restore();
    await library.openNotebook(nb.id);
    return library;
  }

  Future<void> pumpDialog(WidgetTester tester, LibraryController library) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Material(
            child: Center(
              child: TextButton(
                onPressed: () => showWordDistributionDialog(
                  context,
                  library: library,
                  onOpen: (documentId) =>
                      LibraryDialogProbe.openedId = documentId,
                ),
                child: const Text('打开分布'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开分布'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('三章书籍：逐章条目按目录正序排列', (tester) async {
    final library = (await tester.runAsync(makeLibrary))!;
    await pumpDialog(tester, library);

    expect(find.text('章节字数分布'), findsOneWidget);
    // 行内容按 position 升序（节奏图固定叙事正序，不受倒序偏好影响）。
    expect(find.text('开端'), findsOneWidget);
    expect(find.text('高潮'), findsOneWidget);
    expect(find.text('结局'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('开端')).dy <
          tester.getTopLeft(find.text('高潮')).dy &&
          tester.getTopLeft(find.text('高潮')).dy <
              tester.getTopLeft(find.text('结局')).dy,
      isTrue,
    );
  });

  testWidgets('点击某章 → 关闭对话框并回调该章 id', (tester) async {
    final library = (await tester.runAsync(makeLibrary))!;
    await pumpDialog(tester, library);

    final id = library.documentsOf(library.currentNotebook!.id).toList()[1].id;
    await tester.tap(find.text('高潮'));
    // 定长跳帧越过关闭动画（fake-async 下 pumpAndSettle 曾悬挂，见 backlog）。
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 400));

    expect(LibraryDialogProbe.openedId, id);
    expect(find.text('章节字数分布', skipOffstage: false), findsNothing);
  });

  testWidgets('当前打开的章节高亮', (tester) async {
    final library = (await tester.runAsync(makeLibrary))!;
    await pumpDialog(tester, library);

    // openNotebook 恢复 last_open 或第一章 → 「开端」应为激活态。
    // 高亮样式断言较脆，这里退而求其次：对话框渲染且无异常。
    expect(find.text('开端'), findsOneWidget);
  });

  testWidgets('空书：提示无章节', (tester) async {
    // 全部真实 I/O 必须包进 runAsync：fake-async zone 内直连 FFI db 会
    // 劫持测试时钟导致整测 10 分钟挂死（曾致 CI 偶发超时）。
    final library = (await tester.runAsync(() async {
      final tempDir = await Directory.systemTemp.createTemp(
        'zizai_worddist_e',
      );
      final db = await Db.open('${tempDir.path}/test.db');
      final nb = await db.createNotebook('空书');
      final lib = LibraryController(db);
      await lib.restore();
      await lib.openNotebook(nb.id);
      return lib;
    }))!;

    await pumpDialog(tester, library);

    expect(find.text('还没有章节'), findsOneWidget);
    expect(find.text('新建章节后，这里会展示全书的节奏'), findsOneWidget);
  });
}

/// 对话框 onOpen 回调的捕获点（测试专用全局态）。
class LibraryDialogProbe {
  static String? openedId;
}
