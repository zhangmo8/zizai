import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zi_zai/core/update.dart';

/// 更新流程端到端：本地真实 HTTP 服务器 serve update.json + 安装包，
/// UpdateChecker 走真实下载/校验/落盘（非 mock）。
void main() {
  late HttpServer server;
  late Directory tempDir;
  late String base;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_update_e2e');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';

    final packageBody = 'zizai-1.1.0-package-bytes';
    final packageSha =
        crypto.sha256.convert(utf8.encode(packageBody)).toString();
    final manifest = jsonEncode({
      'latest': '1.1.0',
      'minDbSchema': 2,
      'platforms': {
        'macos': {'url': '$base/zizai-1.1.0-macos.zip', 'sha256': packageSha},
      },
      'notes': '端到端测试更新',
    });

    server.listen((req) async {
      if (req.uri.path == '/update.json') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(manifest);
      } else if (req.uri.path.endsWith('.zip')) {
        req.response.add(utf8.encode(packageBody));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('真实链路：清单 → 版本比较 → 下载 → sha256 校验 → 安装包就绪', () async {
    final checker = UpdateChecker(
      httpClient: http.Client(),
      updateUrl: '$base/update.json',
      appVersion: '1.0.0',
      dbSchemaVersion: 2, // minDbSchema=2 满足
      installDir: Directory('${tempDir.path}/updates'),
    );
    await Directory('${tempDir.path}/updates').create();

    final manifest = await checker.checkForUpdate();
    expect(manifest!.latest, '1.1.0');
    expect(checker.status.value, UpdateStatus.ready);
    final file = File(checker.readyPath.value!);
    expect(await file.readAsString(), 'zizai-1.1.0-package-bytes');
  });

  test('真实链路：当前版本最新 → 无更新', () async {
    final checker = UpdateChecker(
      httpClient: http.Client(),
      updateUrl: '$base/update.json',
      appVersion: '1.1.0', // 已是最新
      dbSchemaVersion: 2,
      installDir: Directory('${tempDir.path}/updates2'),
    );
    final manifest = await checker.checkForUpdate();
    expect(manifest, isNull);
    expect(checker.status.value, UpdateStatus.none);
  });

  test('真实链路：清单损坏 sha256 → 拒绝安装', () async {
    // 用坏 sha256 的清单：单独起一个服务器
    final badServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final badManifest = jsonEncode({
      'latest': '1.1.0',
      'minDbSchema': 1,
      'platforms': {
        'macos': {
          'url': '$base/zizai-1.1.0-macos.zip',
          'sha256': '0' * 64, // 伪造
        },
      },
    });
    badServer.listen((req) async {
      req.response
        ..headers.contentType = ContentType.json
        ..write(badManifest);
      await req.response.close();
    });

    final checker = UpdateChecker(
      httpClient: http.Client(),
      updateUrl: 'http://127.0.0.1:${badServer.port}/update.json',
      appVersion: '1.0.0',
      dbSchemaVersion: 1,
      installDir: Directory('${tempDir.path}/updates3'),
    );
    await expectLater(
      checker.checkForUpdate(),
      throwsA(isA<UpdateException>()),
    );
    expect(checker.status.value, UpdateStatus.error);
    expect(checker.error.value, contains('sha256'));
    await badServer.close(force: true);
  });
}
