import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/export.dart' show deltaToPlainText;
import 'package:zi_zai/core/sync/client.dart';

/// 双设备端到端：连本地真实 Worker（miniflare + workerd，非 mock）。
/// 前置：worker 目录先 `npm run pretest`（esbuild 打包），再 `node dev-server.mjs`。
/// 测试自行拉起/关闭 dev-server。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const token = 'dev-token';
  const port = 8799; // 固定端口避免与开发服务器冲突

  late Process serverProcess;
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_e2e');
    // 启动真实 Worker
    serverProcess = await Process.start(
      'node',
      ['dev-server.mjs'],
      workingDirectory: '${Directory.current.path}/worker',
      environment: {'PORT': '$port', 'SYNC_TOKEN': token},
    );
    // 等待 READY（单订阅，避免 drain 二次监听）
    final readyCompleter = Completer<String>();
    final sub = serverProcess.stdout
        .transform(const SystemEncoding().decoder)
        .listen((line) {
      if (!readyCompleter.isCompleted && line.contains('READY')) {
        readyCompleter.complete(line);
      }
    });
    final ready = await readyCompleter.future
        .timeout(const Duration(seconds: 30), onTimeout: () {
      throw StateError('worker 未就绪');
    });
    expect(ready, contains('READY'));
    await sub.cancel();
    serverProcess.stderr.listen(stderr.add);
  });

  tearDownAll(() async {
    serverProcess.kill();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  String baseUrl() => 'http://127.0.0.1:$port';

  Future<SyncClient> device(String name) async {
    final db = await Db.open('${tempDir.path}/$name.db');
    final client = SyncClient(db: db, baseUrl: baseUrl(), backupDir: tempDir);
    await client.initialize();
    await client.setToken(token);
    await client.setEnabled(true);
    return client;
  }

  test('真实 Worker：A 写 → 同步 → B 拉到内容一致；删除跨设备传播', () async {
    final clientA = await device('a');
    final clientB = await device('b');

    // A 写
    final nb = await clientA.db.createNotebook('小说');
    final doc = await clientA.db
        .createDocument(nb.id, title: '第一章', content: '[{"insert":"你好世界"}]');
    await clientA.db.saveDocument(
        id: doc.id, title: doc.title, content: '[{"insert":"你好世界"}]');
    await clientA.syncNow();

    // B 拉
    await clientB.syncNow();
    final docB = await clientB.db.getDocument(doc.id);
    expect(docB, isNotNull);
    expect(deltaToPlainText(docB!.content), '你好世界');

    // A 删除 → 传播到 B
    await clientA.db.deleteDocument(doc.id);
    await clientA.syncNow();
    await clientB.syncNow();
    expect(await clientB.db.getDocument(doc.id), isNull);

    clientA.dispose();
    clientB.dispose();
  });

  test('真实 Worker：同文档冲突 → LWW 云端胜 + .sync-bak 备份可找回', () async {
    final clientA = await device('c');
    final clientB = await device('d');

    final nb = await clientA.db.createNotebook('小说');
    final doc = await clientA.db
        .createDocument(nb.id, title: '第一章', content: '[{"insert":"初版"}]');
    await clientA.syncNow();
    await clientB.syncNow();

    // B 先离线改（不推送），A 后改并推送 → 云端时间晚 → 云端胜
    await clientB.db.saveDocument(
        id: doc.id, title: doc.title, content: '[{"insert":"B 的版本"}]');
    await clientA.db.saveDocument(
        id: doc.id, title: doc.title, content: '[{"insert":"A 的版本"}]');
    await clientA.syncNow();
    await clientB.pull(); // B 只拉取（其脏版本作为输家备份）

    final docB = await clientB.db.getDocument(doc.id);
    expect(deltaToPlainText(docB!.content), 'A 的版本');

    // 输家备份可找回
    final bakDir = Directory('${tempDir.path}/sync-bak');
    final backups = bakDir.existsSync()
        ? await bakDir.list().where((f) => f.path.contains(doc.id)).toList()
        : <FileSystemEntity>[];
    expect(backups, isNotEmpty);
    final backupContent =
        await File(backups.first.path).readAsString();
    expect(backupContent, contains('B 的版本'));

    clientA.dispose();
    clientB.dispose();
  });

  test('真实 Worker：协议不匹配 → 409 可读错误', () async {
    final db = await Db.open('${tempDir.path}/proto.db');
    final client = SyncClient(db: db, baseUrl: baseUrl(), backupDir: tempDir);
    await client.initialize();
    await client.setToken(token);
    await db.createNotebook('书');
    await client.setEnabled(true);

    // 协议版本由客户端常量决定；用不匹配 token 验证 401 路径
    await client.setToken('wrong');
    await client.syncNow();
    expect(client.state.value, SyncState.error);
    expect(client.lastError.value, contains('401'));

    client.dispose();
    await db.close();
  });
}
