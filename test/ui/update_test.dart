import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/update.dart';
import 'package:zi_zai/main.dart' show StartupErrorView;
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';
import 'package:zi_zai/ui/settings_view.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_upd_ui');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  String shaOf(String content) =>
      crypto.sha256.convert(utf8.encode(content)).toString();

  /// 注入的更新源：清单 + 安装包（真实 http MockClient 路由）。
  UpdateChecker makeChecker({String latest = '1.1.0'}) {
    const packageBody = 'package-bytes';
    final sha = shaOf(packageBody);
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/update.json')) {
        return http.Response(
          jsonEncode({
            'latest': latest,
            'minDbSchema': 2,
            'platforms': {
              'macos': {
                'url': 'http://fake/zizai-$latest-macos.zip',
                'sha256': sha,
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response.bytes(utf8.encode(packageBody), 200);
    });
    return UpdateChecker(
      httpClient: client,
      updateUrl: 'http://fake/update.json',
      appVersion: '1.0.0',
      dbSchemaVersion: 2,
      installDir: Directory('${tempDir.path}/updates'),
    );
  }

  Future<void> pumpSettings(
    WidgetTester tester, {
    required UpdateChecker checker,
    required Db db,
  }) async {
    final settings = SettingsController(db);
    final library = LibraryController(db);
    await tester.runAsync(() async {
      await settings.load();
      await library.restore();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            settings: settings,
            library: library,
            updateChecker: checker,
            dbSchemaVersion: 2,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openAbout(WidgetTester tester) async {
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  testWidgets('关于区：App 版本 / 数据库版本 / 检查更新渲染', (tester) async {
    final db = (await tester.runAsync(() => Db.open('${tempDir.path}/t.db')))!;
    final checker = makeChecker();
    await pumpSettings(tester, checker: checker, db: db);
    await openAbout(tester);
    expect(find.text('关于'), findsWidgets);
    expect(find.text('1.0.0'), findsWidgets); // App 版本（注入，可能与其它数值同文案）
    expect(find.text('schema v2'), findsOneWidget);
    expect(find.text('检查更新'), findsWidgets); // 行标签 + 按钮
    await tester.runAsync(() => db.close());
  });

  testWidgets('检查更新流程：检查 → 发现新版（待确认）→ 下载安装 → 就绪', (tester) async {
    final db = (await tester.runAsync(() => Db.open('${tempDir.path}/t.db')))!;
    final checker = makeChecker();
    await pumpSettings(tester, checker: checker, db: db);
    await openAbout(tester);

    // 第一步：检查 → available（待用户确认，不自动下载）
    await tester.tap(find.text('检查更新').last);
    await settle(tester);
    expect(checker.status.value, UpdateStatus.available);
    expect(find.text('下载并安装 v1.1.0'), findsOneWidget);
    // 尚未下载：安装包未就绪
    expect(find.text('发现新版本 v1.1.0'), findsOneWidget);

    // 第二步：确认下载 → ready
    await tester.tap(find.text('下载并安装 v1.1.0'));
    await settle(tester);
    expect(checker.status.value, UpdateStatus.ready);
    expect(find.text('v1.1.0 已下载并通过校验'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.runAsync(() => db.close());
  });

  testWidgets('启动失败视图：迁移失败提示 + .bak 恢复指引', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StartupErrorView(
          message: '打开数据库失败: 测试错误',
          path: '/tmp/zi-zai.db',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('启动失败'), findsOneWidget);
    expect(find.textContaining('打开数据库失败'), findsOneWidget);
    expect(find.textContaining('.bak'), findsOneWidget);
    expect(find.textContaining('/tmp/zi-zai.db'), findsOneWidget);
  });
}
