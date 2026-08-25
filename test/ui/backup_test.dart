import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/backup/backup.dart';
import 'package:zi_zai/core/backup/s3_store.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';
import 'package:zi_zai/ui/zz.dart';

/// sync-ui-003：备份设置区 + 状态栏备份指示（docs/app/ui-settings.md §备份、ui-shell.md 指示规则）。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  S3Store makeStore({required Future<http.Response> Function() onRequest}) =>
      S3Store(
        accountId: 'acc',
        bucket: 'bkt',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: MockClient((_) => onRequest()),
      );

  Future<(Db, LibraryController, SettingsController)> makeControllers() async {
    final dir = await Directory.systemTemp.createTemp('zizai_backup');
    final db = await Db.open('${dir.path}/test.db');
    final nb = await db.createNotebook('小说');
    final doc = await db.createDocument(
      nb.id,
      title: '第一章',
      content: '[{"insert":"正文"}]',
    );
    await db.saveLastOpen(notebookId: nb.id, documentId: doc.id, words: 2);
    final settings = SettingsController(db);
    await settings.load();
    final library = LibraryController(db);
    await library.restore();
    return (db, library, settings);
  }

  Future<void> pumpApp(
    WidgetTester tester,
    LibraryController library,
    SettingsController settings,
    BackupManager backup,
  ) async {
    await tester.pumpWidget(
      ZiZaiApp(library: library, settings: settings, backup: backup),
    );
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
  }

  /// 让真实异步（sqflite / mock http）在 FakeAsync 外完成（25×40ms≈1s，
  /// 同 shell_test.settleDatabaseWrite；5 轮在 CI 慢机上偶发未落盘）。
  Future<void> settleAsync(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  Future<void> openBackupSection(WidgetTester tester) async {
    // 已配置 → 走状态栏备份指示（留在单书工作区，指示与当前文档状态保持）；
    // 未配置（指示隐藏）→ 回管理页顶栏打开全局设置。
    final indicator = find.byTooltip('未备份');
    if (indicator.evaluate().isNotEmpty) {
      await tester.tap(indicator);
      await tester.pumpAndSettle();
      return;
    }
    final back = find.byTooltip('返回笔记本管理');
    if (back.evaluate().isNotEmpty) {
      await tester.tap(back);
      // closeNotebook 先 await 编辑器 beforeSwitchSave（真实写库），多轮推进后切回管理页。
      await settleAsync(tester);
    }
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('备份').first);
    await tester.pumpAndSettle();
  }

  testWidgets('未配置凭据：操作按钮禁用 + 引导文案，状态栏指示隐藏', (tester) async {
    final (db, library, settings) =
        (await tester.runAsync(makeControllers))!;
    final backup = BackupManager(db: db, dbPath: '');
    await pumpApp(tester, library, settings, backup);

    expect(find.text('未备份'), findsNothing); // 指示整体隐藏
    expect(find.byIcon(Icons.cloud_outlined), findsNothing);

    await openBackupSection(tester);
    expect(find.text('填写四项 R2 凭据后即可备份（Secret 仅存本机）'), findsOneWidget);
    final upload = tester.widget<ZzButton>(
      find.widgetWithText(ZzButton, '上传备份'),
    );
    expect(upload.onPressed, isNull);
    await settleAsync(tester);
    await tester.pump(const Duration(seconds: 6)); // 释放挂起计时器（editor 内有 5s 计时器）
  });

  testWidgets('凭据输入保存 → settings 表持久化 + 重开回填 + Secret 掩码', (tester) async {
    final (db, library, settings) =
        (await tester.runAsync(makeControllers))!;
    final backup = BackupManager(db: db, dbPath: '');
    await pumpApp(tester, library, settings, backup);
    await openBackupSection(tester);

    final fields = find.byType(TextField);
    Future<void> submit(int index, String text) async {
      await tester.enterText(fields.at(index), text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleAsync(tester);
    }

    await submit(0, 'acc123');
    await submit(1, 'my-bucket');
    await submit(2, 'AKID');
    await submit(3, 'SECRET');

    expect(await tester.runAsync(() => db.getSetting('backup.accountId')),
        'acc123');
    expect(await tester.runAsync(() => db.getSetting('backup.secretKey')),
        'SECRET');
    expect(backup.configured, isTrue);

    // Secret 字段掩码
    final secretField = tester.widget<TextField>(fields.at(3));
    expect(secretField.obscureText, isTrue);

    // 重开设置页回填
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await openBackupSection(tester);
    await settleAsync(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller?.text,
      'acc123',
    );
  });

  testWidgets('立即备份成功 → 上次备份刷新 + 指示转「已备份」', (tester) async {
    final (db, library, settings) =
        (await tester.runAsync(makeControllers))!;
    final backup = BackupManager(
      db: db,
      dbPath: '',
      store: makeStore(onRequest: () async => http.Response('', 200)),
    );
    await pumpApp(tester, library, settings, backup);

    // 已配置 + 未备份 → 中性指示
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);

    // 备份中瞬态 → ⟳ 指示
    backup.state.value = BackupState.uploading;
    await tester.pump();
    expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);
    backup.state.value = BackupState.idle;
    await tester.pump();

    await openBackupSection(tester);
    expect(find.text('从未备份'), findsOneWidget);

    await tester.tap(find.text('上传备份'));
    await settleAsync(tester);

    expect(find.text('备份已上传'), findsOneWidget); // toast
    expect(find.text('从未备份'), findsNothing);
    expect(backup.lastBackupAt.value, isNotNull);
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // 等 toast 自动消退
  });

  testWidgets('备份失败 → 错误 + 重试按钮 + 指示「失败 n 次」', (tester) async {
    final (db, library, settings) =
        (await tester.runAsync(makeControllers))!;
    final backup = BackupManager(
      db: db,
      dbPath: '',
      store: makeStore(onRequest: () async => http.Response('', 500)),
    );
    await pumpApp(tester, library, settings, backup);
    await openBackupSection(tester);

    await tester.tap(find.text('上传备份'));
    await settleAsync(tester);

    expect(backup.state.value, BackupState.error);
    expect(backup.failureCount.value, 1);
    expect(find.text('重试'), findsOneWidget);
    expect(find.textContaining('上传失败'), findsWidgets);
    expect(find.byIcon(Icons.sync_problem_outlined), findsOneWidget);
    expect(find.byTooltip('失败 1 次'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // 等 toast 自动消退
  });

  testWidgets('下载恢复 → 二次确认（含 .bak 提示）；取消不动本地库', (tester) async {
    final (db, library, settings) =
        (await tester.runAsync(makeControllers))!;
    var getCalled = 0;
    final backup = BackupManager(
      db: db,
      dbPath: '',
      store: makeStore(onRequest: () async {
        getCalled++;
        return http.Response('', 404);
      }),
    );
    await pumpApp(tester, library, settings, backup);
    await openBackupSection(tester);

    await tester.tap(find.text('下载恢复'));
    await tester.pumpAndSettle();
    expect(find.textContaining('.bak'), findsOneWidget); // 兜底路径对用户可见
    await tester.tap(find.text('取消'));
    await settleAsync(tester);

    expect(getCalled, 0); // 未发请求
    final docs = await tester.runAsync(() => db.listAllDocuments());
    expect(docs, isNotNull); // 库仍可用且文档保留
    expect(library.currentDocument?.title, '第一章');
  });

  testWidgets('状态栏指示点击 → 打开设置页并定位备份区', (tester) async {
    final (db, library, settings) =
        (await tester.runAsync(makeControllers))!;
    final backup = BackupManager(
      db: db,
      dbPath: '',
      store: makeStore(onRequest: () async => http.Response('', 200)),
    );
    await pumpApp(tester, library, settings, backup);

    await tester.tap(find.byTooltip('未备份'));
    await tester.pumpAndSettle();

    expect(find.text('R2 备份'), findsOneWidget); // 备份区已定位展开
    await settleAsync(tester);
    await tester.pump(const Duration(seconds: 6)); // 释放挂起计时器（editor 内有 5s 计时器）
  });
}
