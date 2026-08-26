import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zi_zai/core/app_logger.dart';
import 'package:zi_zai/core/update.dart';

String sha256Of(String content) =>
    crypto.sha256.convert(utf8.encode(content)).toString();

/// 内存更新源：update.json + 安装包。
class FakeUpdateServer {
  FakeUpdateServer({
    this.latest = '1.1.0',
    this.minDbSchema = 1,
    this.platform = 'macos',
    this.changelog = '',
  });

  final String latest;
  final int minDbSchema;
  final String platform;
  final String changelog;

  static const String packageBody = 'fake-installer-bytes';
  late String packageSha = sha256Of(packageBody);

  http.Client client() => MockClient((request) async {
    if (request.url.path.endsWith('/update.json')) {
      return http.Response(
        jsonEncode({
          'latest': latest,
          'minDbSchema': minDbSchema,
          if (changelog.isNotEmpty) 'changelog': changelog,
          'platforms': {
            platform: {
              'url': 'http://fake/zizai-$latest-$platform.zip',
              'sha256': packageSha,
            },
          },
          'notes': '测试更新',
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (request.url.path.endsWith('.zip') ||
        request.url.path.endsWith('.apk')) {
      return http.Response.bytes(utf8.encode(packageBody), 200);
    }
    return http.Response('not found', 404);
  });
}

UpdateChecker checker({
  required FakeUpdateServer server,
  String appVersion = '1.0.0',
  int dbSchemaVersion = 1,
  AppLogger? logger,
  required Directory dir,
}) => UpdateChecker(
  httpClient: server.client(),
  updateUrl: 'http://fake/update.json',
  appVersion: appVersion,
  dbSchemaVersion: dbSchemaVersion,
  installDir: dir,
  logger: logger,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_update');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('compareVersions', () {
    test('语义化比较', () {
      expect(compareVersions('1.0.0', '1.0.0'), 0);
      expect(compareVersions('1.0.0', '1.0.1'), -1);
      expect(compareVersions('1.1.0', '1.0.9'), 1);
      expect(compareVersions('2.0.0', '1.9.9'), 1);
      expect(compareVersions('1.0.0', '1.0'), 0);
      expect(compareVersions('1.0.1', '1.0'), 1);
    });
  });

  group('清单与版本协商', () {
    test('无新版本 → null', () async {
      final c = checker(
        server: FakeUpdateServer(latest: '1.0.0'),
        dir: tempDir,
      );
      expect(await c.fetchManifest(), isNull);
    });

    test('有新版且 minDbSchema 满足 → 返回清单', () async {
      final c = checker(
        server: FakeUpdateServer(latest: '1.1.0'),
        dir: tempDir,
      );
      final m = await c.fetchManifest();
      expect(m!.latest, '1.1.0');
    });

    test('清单带 changelog → 解析并保留给 UI', () async {
      final c = checker(
        server: FakeUpdateServer(
          latest: '1.1.0',
          changelog: '- feat(mcp): 本地 MCP 服务\n- fix(ui): 黄线修复',
        ),
        dir: tempDir,
      );
      final m = await c.check();
      expect(m!.changelog, contains('本地 MCP 服务'));
      // check() 后 UI 可从 lastManifest 读取 changelog 弹窗。
      expect(c.lastManifest, same(m));
    });

    test('minDbSchema 高于本地 → 拒绝并报可读错误', () async {
      final c = checker(
        server: FakeUpdateServer(latest: '1.1.0', minDbSchema: 3),
        dbSchemaVersion: 2,
        dir: tempDir,
      );
      expect(c.fetchManifest(), throwsA(isA<UpdateException>()));
    });
  });

  group('下载与校验', () {
    test('sha256 匹配 → 下载成功落盘', () async {
      final c = checker(server: FakeUpdateServer(), dir: tempDir);
      final m = await c.fetchManifest();
      final file = await c.download(
        m!.platforms['macos']!.url,
        m.platforms['macos']!.sha256,
      );
      expect(await file.readAsString(), 'fake-installer-bytes');
    });

    test('sha256 不符 → 拒绝安装并报错', () async {
      // 篡改清单里的 sha256
      final tampered = FakeUpdateServer()..packageSha = '0' * 64;
      final c = checker(server: tampered, dir: tempDir);
      final m = await c.fetchManifest();
      expect(
        c.download(m!.platforms['macos']!.url, m.platforms['macos']!.sha256),
        throwsA(isA<UpdateException>()),
      );
    });

    test('更新失败写入本地诊断日志', () async {
      final logger = await AppLogger.create(tempDir);
      final tampered = FakeUpdateServer()..packageSha = '0' * 64;
      final c = checker(server: tampered, dir: tempDir, logger: logger);

      await expectLater(c.checkForUpdate(), throwsA(isA<UpdateException>()));

      final log = await File(logger.path).readAsString();
      expect(log, contains('update.download.start'));
      expect(log, contains('update.install.failed'));
      expect(log, contains('sha256'));
    });
  });

  test('checkForUpdate 全链路：manifest → 下载 → ready', () async {
    final c = checker(server: FakeUpdateServer(), dir: tempDir);
    final m = await c.checkForUpdate();
    expect(m!.latest, '1.1.0');
    expect(c.status.value, UpdateStatus.ready);
    expect(c.readyPath.value, isNotNull);
    expect(File(c.readyPath.value!).existsSync(), isTrue);
  });

  test('无新版本 → status none，不下载', () async {
    final c = checker(
      server: FakeUpdateServer(latest: '1.0.0'),
      dir: tempDir,
    );
    final m = await c.checkForUpdate();
    expect(m, isNull);
    expect(c.status.value, UpdateStatus.none);
  });
}
