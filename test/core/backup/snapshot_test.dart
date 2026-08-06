/// 快照测试：全量导出（凭据剔除）/ 恢复导入往返 / 非法快照拒绝。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/backup/snapshot.dart';
import 'package:zi_zai/core/db.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_snapshot');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<Db> openDb(String name) => Db.open('${tempDir.path}/$name.db');

  /// 种子库：笔记本/文档/设置（含 sync.*、backup.* 本地键）/ stats。
  Future<Db> seed() async {
    final db = await openDb('seed');
    final nb = await db.createNotebook('诗集');
    await db.createDocument(nb.id, title: '静夜思', content:
        '[{"insert":"床前明月光\\n"}]');
    await db.setSetting('theme', 'dark');
    await db.setSetting('sync.token', 'shh-secret'); // 不得进入快照
    await db.setSetting('backup.secretKey', 'shh-key'); // 不得进入快照
    await db.setSetting('dailyGoal', '3000');
    return db;
  }

  test('快照包含全部业务数据，剔除 sync.* / backup.* 本地键', () async {
    final db = await seed();
    final snap = await buildSnapshot(db, deviceId: 'dev-1', appVersion: '1.0.0');

    expect(snap['format'], 'zizai-backup');
    expect(snap['version'], snapshotFormatVersion);
    expect(snap['schemaVersion'], currentSchemaVersion);
    expect(snap['device'], 'dev-1');

    final data = snap['data'] as Map;
    final settings = (data['settings'] as Map).cast<String, String>();
    expect(settings['theme'], 'dark');
    expect(settings['dailyGoal'], '3000');
    expect(settings.containsKey('sync.token'), isFalse);
    expect(settings.containsKey('backup.secretKey'), isFalse);

    expect((data['notebooks'] as List).length, 1);
    expect((data['docs'] as List).length, 1);
    final doc = (data['docs'] as List).first as Map;
    expect(doc['title'], '静夜思');
    expect(doc['content'], contains('床前明月光'));
    await db.close();
  });

  test('恢复导入：往返后数据一致（含删除的本地键不复原）', () async {
    final db = await seed();
    final snap = await buildSnapshot(db, deviceId: 'dev-1');
    await db.close();

    final target = await openDb('target');
    await target.createNotebook('本地临时'); // 恢复前先有脏数据
    final result =
        await importSnapshot(target, jsonEncode(snap), dbPath: '');
    expect(result.notebooks, 1);
    expect(result.docs, 1);

    final notebooks = await target.listNotebooks();
    expect(notebooks.single.name, '诗集');
    final docs = await target.listAllDocuments();
    expect(docs.single.title, '静夜思');
    final settings = await target.allSettings();
    expect(settings['theme'], 'dark');
    expect(settings.containsKey('sync.token'), isFalse);
    // 恢复后本地原 settings 表被清空重建（theme 来自快照）
    await target.close();
  });

  test('非法输入全部拒绝：坏 JSON / 非备份格式 / 未来格式', () async {
    final db = await openDb('reject');
    await expectLater(importSnapshot(db, 'not-json', dbPath: ''),
        throwsA(isA<BackupException>()));
    await expectLater(
        importSnapshot(db, '{"format":"other","version":1}', dbPath: ''),
        throwsA(isA<BackupException>()));
    await expectLater(
        importSnapshot(
            db,
            '{"format":"zizai-backup","version":${snapshotFormatVersion + 1}'
            ',"data":{}}',
            dbPath: ''),
        throwsA(isA<BackupException>()));
    await db.close();
  });

  test('恢复前生成本地 .bak（dbPath 非空时）', () async {
    final db = await seed();
    final snap = await buildSnapshot(db);
    await db.close();

    final target = await openDb('bak_target');
    await target.createNotebook('将被覆盖');
    await target.close();

    final reopen = await openDb('bak_target');
    await importSnapshot(
        reopen, jsonEncode(snap), dbPath: '${tempDir.path}/bak_target.db');
    await reopen.close();

    expect(File('${tempDir.path}/bak_target.db.bak').existsSync(), isTrue);
  });
}
