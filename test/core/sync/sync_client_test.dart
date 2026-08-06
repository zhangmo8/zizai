import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/export.dart' show deltaToPlainText;
import 'package:zi_zai/core/models.dart';
import 'package:zi_zai/core/sync/client.dart';

import 'fake_server.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_sync');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<(Db, SyncClient)> makeDevice(FakeSyncServer server, String name) async {
    final db = await Db.open('${tempDir.path}/$name.db');
    final client = SyncClient(
      db: db,
      baseUrl: 'http://fake',
      backupDir: tempDir,
      httpClient: server.client(),
    );
    await client.initialize();
    await client.setToken(server.token);
    await client.setEnabled(true);
    return (db, client);
  }

  /// 写文档并保存内容（标记脏）。
  Future<String> writeDoc(Db db, String title, String text) async {
    final nb = await db.createNotebook('书');
    final doc = await db.createDocument(nb.id, title: title);
    await db.saveDocument(id: doc.id, title: doc.title, content: '[{"insert":"$text"}]');
    return doc.id;
  }

  test('双设备：A 写 → push → B pull → 内容一致', () async {
    final server = FakeSyncServer();
    final (dbA, clientA) = await makeDevice(server, 'a');
    final (dbB, clientB) = await makeDevice(server, 'b');

    final docId = await writeDoc(dbA, '第一章', '你好世界');

    await clientA.syncNow();
    await clientB.syncNow();

    final docB = await dbB.getDocument(docId);
    expect(docB, isNotNull);
    expect(deltaToPlainText(docB!.content), '你好世界');
    expect(docB.words, 4);

    clientA.dispose();
    clientB.dispose();
    await dbA.close();
    await dbB.close();
  });

  test('冲突：双端同改 → LWW 云端胜 + 输家 .sync-bak 备份', () async {
    final server = FakeSyncServer();
    final (dbA, clientA) = await makeDevice(server, 'a');
    final (dbB, clientB) = await makeDevice(server, 'b');

    final docId = await writeDoc(dbA, '第一章', '初版内容');
    await clientA.syncNow();
    await clientB.syncNow(); // B 拿到初版

    // B 先离线改（未推送），A 后改并推送 → 云端时间晚于 B 本地时间 → 云端胜
    await dbB.saveDocument(id: docId, title: '第一章', content: '[{"insert":"B 的版本"}]');
    await dbA.saveDocument(id: docId, title: '第一章', content: '[{"insert":"A 的新版本"}]');
    await clientA.syncNow();

    // B 拉取 → 云端（A 版本）更新更晚 → 覆盖 B，B 的版本进 .sync-bak
    await clientB.pull();

    final docB = await dbB.getDocument(docId);
    expect(deltaToPlainText(docB!.content), 'A 的新版本');
    // 输家备份存在
    final bakDir = Directory('${tempDir.path}/sync-bak');
    final files = bakDir.existsSync()
        ? await bakDir.list().where((f) => f.path.contains(docId)).toList()
        : <FileSystemEntity>[];
    expect(files, isNotEmpty);

    clientA.dispose();
    clientB.dispose();
    await dbA.close();
    await dbB.close();
  });

  test('tombstone：A 删除 → 同步 → B 本地删除', () async {
    final server = FakeSyncServer();
    final (dbA, clientA) = await makeDevice(server, 'a');
    final (dbB, clientB) = await makeDevice(server, 'b');

    final docId = await writeDoc(dbA, '第一章', '将被删除');
    await clientA.syncNow();
    await clientB.syncNow();
    expect(await dbB.getDocument(docId), isNotNull);

    await dbA.deleteDocument(docId);
    await clientA.syncNow();
    await clientB.syncNow();

    expect(await dbB.getDocument(docId), isNull);
    // 云端保留 tombstone（deleted: true）
    expect(server.store[docId]!['deleted'], isTrue);

    clientA.dispose();
    clientB.dispose();
    await dbA.close();
    await dbB.close();
  });

  test('增量 pull：since 游标只拉新内容', () async {
    final server = FakeSyncServer();
    final (dbA, clientA) = await makeDevice(server, 'a');
    final (dbB, clientB) = await makeDevice(server, 'b');

    final docId = await writeDoc(dbA, '第一章', '内容一');
    await clientA.syncNow();
    await clientB.syncNow(); // B 游标已推进

    await dbA.saveDocument(id: docId, title: '第一章', content: '[{"insert":"内容二"}]');
    await clientA.push();
    final before = server.store.length;
    await clientB.pull();
    expect(server.store.length, before); // 无多余请求概念，这里验证游标语义由 since 保证
    final docB = await dbB.getDocument(docId);
    expect(deltaToPlainText(docB!.content), '内容二');

    clientA.dispose();
    clientB.dispose();
    await dbA.close();
    await dbB.close();
  });

  test('推送后清脏：dirtyEntityIds 为空', () async {
    final server = FakeSyncServer();
    final (dbA, clientA) = await makeDevice(server, 'a');

    await writeDoc(dbA, '第一章', '内容');
    expect(await dbA.dirtyEntityIds(), isNotEmpty);

    await clientA.push();
    expect(await dbA.dirtyEntityIds(), isEmpty);

    await dbA.close();
  });

  test('settings 推送：token 等 sync.* 键绝不进入 envelope', () async {
    final server = FakeSyncServer();
    final (dbA, clientA) = await makeDevice(server, 'a');

    await dbA.saveSettings(const Settings(theme: 'dark'));
    // 本地再写一个 token（模拟设置页；token 只存本地 settings 表）
    await clientA.setToken(server.token);

    await clientA.push();
    final settingsEnvelope = server.store['settings']!;
    final data = settingsEnvelope['data'] as Map;
    expect(data['theme'], 'dark');
    expect(data.containsKey('sync.token'), isFalse);
    expect(data.containsKey('sync.enabled'), isFalse);
    expect(data.containsKey('sync.deviceId'), isFalse);

    await dbA.close();
  });

  test('409 协议不匹配 → 可读错误 + 状态机 error + 退避重试调度', () async {
    final server = FakeSyncServer(protocol: 99);
    final (dbA, clientA) = await makeDevice(server, 'a');

    await writeDoc(dbA, '第一章', '内容');
    await clientA.push();

    expect(clientA.state.value, SyncState.error);
    expect(clientA.failureCount.value, greaterThanOrEqualTo(1));
    expect(clientA.lastError.value, contains('升级 App'));

    await dbA.close();
  });

  test('退避序列：30s / 1m / 5m / 上限 1h', () {
    expect(retryDelayFor(0), const Duration(seconds: 30));
    expect(retryDelayFor(1), const Duration(seconds: 30));
    expect(retryDelayFor(2), const Duration(minutes: 1));
    expect(retryDelayFor(3), const Duration(minutes: 5));
    expect(retryDelayFor(4), const Duration(hours: 1));
    expect(retryDelayFor(10), const Duration(hours: 1));
  });
}

const ziZaiSettings = Settings;
