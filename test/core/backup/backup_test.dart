/// BackupManager 测试：未配置拒绝、上传/下载流程、快照凭据剔除。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/backup/backup.dart';
import 'package:zi_zai/core/backup/s3_store.dart';
import 'package:zi_zai/core/backup/snapshot.dart';
import 'package:zi_zai/core/db.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_backup');
    dbPath = '${tempDir.path}/app.db';
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<Db> openDb([String? path]) =>
      Db.open(path ?? dbPath);

  /// 内存桶：MockClient 充当 R2（PUT 存 / GET 取，404 = 无对象）。
  (S3Store, Map<String, List<int>>) memoryStore() {
    final bucket = <String, List<int>>{};
    final client = MockClient((req) async {
      final key = req.url.pathSegments.last;
      if (req.method == 'PUT') {
        bucket[key] = req.bodyBytes;
        return http.Response('', 200);
      }
      final bytes = bucket[key];
      return bytes == null
          ? http.Response('Not Found', 404)
          : http.Response.bytes(bytes, 200);
    });
    return (
      S3Store(
        accountId: 'acct',
        bucket: 'bkt',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: client,
      ),
      bucket,
    );
  }

  test('未配置：upload/download 直接返回 false 且不改状态', () async {
    final db = await openDb();
    final backup = BackupManager(db: db, dbPath: dbPath);
    expect(backup.configured, isFalse);
    expect(await backup.upload(), isFalse);
    expect(await backup.download(), isFalse);
    expect(backup.state.value, BackupState.idle);
    await db.close();
  });

  test('上传 → 云端有快照；快照不含 backup.secretKey', () async {
    final db = await openDb();
    final nb = await db.createNotebook('备份测试');
    await db.createDocument(nb.id, title: '一篇');
    await db.setSetting('backup.secretKey', 'shh'); // 只存本地
    final (store, bucket) = memoryStore();
    final backup = BackupManager(db: db, dbPath: dbPath, store: store);

    expect(await backup.upload(deviceId: 'dev', appVersion: '1.0.0'), isTrue);
    expect(backup.state.value, BackupState.idle);
    expect(backup.lastBackupAt.value, isNotNull);
    expect(backup.lastError.value, isNull);

    final remote = bucket[BackupManager.backupKey]!;
    final snap = (jsonDecode(utf8.decode(remote)) as Map).cast<String, dynamic>();
    final settings = (snap['data'] as Map)['settings'] as Map;
    expect(settings.containsKey('backup.secretKey'), isFalse);
    expect((snap['data'] as Map)['docs'], hasLength(1));
    await db.close();
  });

  test('下载恢复：另一台"设备"拉取快照 → 数据一致', () async {
    final dbA = await openDb();
    final nb = await dbA.createNotebook('诗集');
    await dbA.createDocument(nb.id, title: '静夜思',
        content: '[{"insert":"床前明月光\\n"}]');
    final (store, _) = memoryStore();
    final backupA = BackupManager(db: dbA, dbPath: dbPath, store: store);
    expect(await backupA.upload(), isTrue);
    await dbA.close();

    // 设备 B：全新库，下载恢复
    final dbB = await openDb('${tempDir.path}/b.db');
    final backupB = BackupManager(
        db: dbB, dbPath: '${tempDir.path}/b.db', store: store);
    expect(await backupB.download(), isTrue);
    expect(backupB.lastError.value, isNull);

    final docs = await dbB.listAllDocuments();
    expect(docs.single.title, '静夜思');
    final nbs = await dbB.listNotebooks();
    expect(nbs.single.name, '诗集');
    await dbB.close();
  });

  test('云端无备份：download 报错（BackupException）且状态 error', () async {
    final db = await openDb();
    final (store, _) = memoryStore();
    final backup = BackupManager(db: db, dbPath: dbPath, store: store);
    expect(await backup.download(), isFalse);
    expect(backup.state.value, BackupState.error);
    expect(backup.lastError.value, contains('云端还没有备份'));
    await db.close();
  });

  test('上传失败（HTTP 500）→ error 状态 + failureCount 累加', () async {
    final db = await openDb();
    final client = MockClient((_) async => http.Response('boom', 500));
    final store = S3Store(
      accountId: 'a',
      bucket: 'b',
      accessKey: 'k',
      secretKey: 's',
      httpClient: client,
    );
    final backup = BackupManager(db: db, dbPath: dbPath, store: store);
    expect(await backup.upload(), isFalse);
    expect(backup.state.value, BackupState.error);
    expect(backup.failureCount.value, 1);
    await db.close();
  });

  test('本地导出/恢复：文件往返含分卷，恢复前生成 .bak', () async {
    final db = await openDb();
    final nb = await db.createNotebook('诗集');
    final vol = await db.createVolume(nb.id, name: '上卷');
    await db.createDocument(
      nb.id,
      title: '静夜思',
      content: '[{"insert":"床前明月光\\n"}]',
      volumeId: vol.id,
    );
    final backup = BackupManager(db: db, dbPath: dbPath);

    final filePath = '${tempDir.path}/backup.json';
    await backup.exportToFile(filePath, deviceId: 'dev', appVersion: '1.0.0');
    expect(File(filePath).existsSync(), isTrue);
    final raw = jsonDecode(await File(filePath).readAsString()) as Map;
    expect(raw['format'], 'zizai-backup');
    expect((raw['data'] as Map)['volumes'], hasLength(1));
    expect((raw['data'] as Map)['docs'], hasLength(1));
    await db.close();

    // 恢复端：先放脏数据，再从文件恢复（应全量替换 + 生成 .bak）。
    final target = await openDb('${tempDir.path}/target.db');
    await target.createNotebook('本地临时');
    final targetBackup = BackupManager(
      db: target,
      dbPath: '${tempDir.path}/target.db',
    );
    final result = await targetBackup.restoreFromFile(filePath);
    expect(result.notebooks, 1);
    expect(result.volumes, 1);
    expect(result.docs, 1);
    expect((await target.listNotebooks()).single.name, '诗集');
    expect((await target.listAllVolumes()).single.name, '上卷');
    expect(
      File('${tempDir.path}/target.db.bak').existsSync(),
      isTrue,
      reason: '恢复前应生成滚动 .bak',
    );
    await target.close();
  });

  test('本地恢复：坏文件抛 BackupException 且不破坏现有库', () async {
    final db = await openDb();
    await db.createNotebook('保留书');
    final backup = BackupManager(db: db, dbPath: dbPath);
    final badFile = '${tempDir.path}/bad.json';
    await File(badFile).writeAsString('not-a-backup');
    await expectLater(
      backup.restoreFromFile(badFile),
      throwsA(isA<BackupException>()),
    );
    expect((await db.listNotebooks()).single.name, '保留书');
    await db.close();
  });
}
