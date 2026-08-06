import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/app.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/sync/client.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';

import '../core/sync/fake_server.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  Future<(LibraryController, SettingsController, Db, SyncClient, FakeSyncServer)>
      makeApp({bool seed = true}) async {
    tempDir = await Directory.systemTemp.createTemp('zizai_syncui');
    final db = await Db.open('${tempDir.path}/test.db');
    if (seed) {
      final nb = await db.createNotebook('小说');
      final doc = await db.createDocument(nb.id, title: '第一章');
      await db.saveLastOpen(notebookId: nb.id, documentId: doc.id, words: 0);
    }
    final settings = SettingsController(db);
    await settings.load();
    final library = LibraryController(db);
    await library.restore();
    final server = FakeSyncServer();
    final sync = SyncClient(db: db, baseUrl: 'http://fake', backupDir: tempDir,
        httpClient: server.client());
    await sync.initialize();
    await sync.setToken(server.token);
    return (library, settings, db, sync, server);
  }

  Future<void> pumpApp(WidgetTester tester, LibraryController library,
      SettingsController settings, SyncClient? sync) async {
    await tester.pumpWidget(ZiZaiApp(
        library: library, settings: settings, syncClient: sync));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
  }

  Future<void> scrollSettingsDown(WidgetTester tester) async {
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
  }

  testWidgets('同步区：开关/令牌/地址/上次同步/立即同步渲染', (tester) async {
    final (library, settings, _, sync, _) =
        (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings, sync);
    await openSettings(tester);
    await scrollSettingsDown(tester);

    expect(find.text('同步'), findsOneWidget);
    expect(find.text('云同步'), findsOneWidget);
    expect(find.text('同步令牌'), findsOneWidget);
    expect(find.text('同步地址'), findsOneWidget);
    expect(find.text('上次同步'), findsOneWidget);
    expect(find.text('立即同步'), findsOneWidget);
    expect(find.text('从未同步'), findsOneWidget);
  });

  testWidgets('开关切换 → 持久化 + 立即同步成功后「上次同步」刷新', (tester) async {
    final (library, settings, db, sync, server) =
        (await tester.runAsync(() => makeApp()))!;
    // 预置内容可推送
    await tester.runAsync(() async {
      final nb = await db.createNotebook('可同步');
      final doc = await db.createDocument(nb.id, title: '第一章');
      await db.saveDocument(id: doc.id, title: doc.title, content: '[{"insert":"内容"}]');
    });
    await pumpApp(tester, library, settings, sync);
    await openSettings(tester);
    await scrollSettingsDown(tester);

    // 关闭态 → 打开
    await tester.tap(find.byType(Switch));
    // 真实异步（syncNow 全链路）
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    expect(sync.enabled, isTrue);
    expect(await tester.runAsync(() => db.getSetting('sync.enabled')), '1');
    expect(sync.lastSyncAt.value, isNotNull);
    expect(find.text('从未同步'), findsNothing);
    // 服务器收到了推送
    expect(server.store, isNotEmpty);
  });

  testWidgets('令牌输入掩码 + 仅存本地 settings 表', (tester) async {
    final (library, settings, db, sync, _) =
        (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings, sync);
    await openSettings(tester);
    await scrollSettingsDown(tester);

    final tokenField = find.widgetWithText(TextField, 'Worker secret（SYNC_TOKEN）');
    await tester.tap(tokenField);
    await tester.enterText(tokenField, 'my-secret');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    expect(await tester.runAsync(() => db.getSetting('sync.token')), 'my-secret');
    // 掩码显示
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.obscureText, isTrue);
  });

  testWidgets('状态栏同步指示：关闭不显示，开启显示 ●，失败显示 ⚠', (tester) async {
    final (library, settings, db, sync, server) =
        (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings, sync);
    await tester.pump();
    // 默认关闭 → 不显示
    expect(find.textContaining('已同步'), findsNothing);

    // 开启（引擎直接启用 + 同步成功）
    await tester.runAsync(() async {
      await sync.setEnabled(true);
    });
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    expect(find.text('● 已同步'), findsOneWidget);

    // 注入失败：换错误 token → syncNow → error
    await tester.runAsync(() async {
      await sync.setToken('wrong-token');
      await sync.syncNow();
    });
    await tester.pump();
    expect(find.textContaining('失败'), findsOneWidget);
    expect(find.textContaining('⚠'), findsOneWidget);
  });

  testWidgets('B2 回归：关闭开关 → 状态栏指示隐藏 + Switch 重建', (tester) async {
    final (library, settings, db, sync, server) =
        (await tester.runAsync(() => makeApp()))!;
    await pumpApp(tester, library, settings, sync);
    // 开启 → 指示出现
    await tester.runAsync(() => sync.setEnabled(true));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    expect(find.textContaining('已同步'), findsOneWidget);
    // 关闭 → 指示消失
    await tester.runAsync(() => sync.setEnabled(false));
    await tester.pump();
    expect(find.textContaining('已同步'), findsNothing);
    expect(find.textContaining('同步中'), findsNothing);
    expect(find.textContaining('失败'), findsNothing);
  });

  testWidgets('冲突提示：输家备份后设置页显示备份路径', (tester) async {
    final (library, settings, db, sync, server) =
        (await tester.runAsync(() => makeApp()))!;
    // 引擎启用 + 推送一个文档
    await tester.runAsync(() async {
      final nb = await db.createNotebook('书');
      await db.createDocument(nb.id, title: '第一章', content: '[{"insert":"初版"}]');
      await sync.setEnabled(true);
      await sync.setToken(server.token);
    });
    // 让 push 完成
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    // 注入一次冲突备份：直接把计数 +1（等价于 pull 覆盖本地）
    await tester.runAsync(() {
      sync.conflictBackups.value++;
      return Future<void>.value();
    });
    await pumpApp(tester, library, settings, sync);
    await openSettings(tester);
    await scrollSettingsDown(tester);

    expect(find.textContaining('本地版本已备份'), findsOneWidget);
    expect(find.textContaining('sync-bak'), findsOneWidget);
  });
}
