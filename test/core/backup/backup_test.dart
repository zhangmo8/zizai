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
}
