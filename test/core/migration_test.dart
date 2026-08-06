import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/models.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_mig_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  String dbPath() => '${tempDir.path}/zi-zai.db';

  Future<Map<String, Object?>> userVersion(String path) async {
    final db = await databaseFactory.openDatabase(path);
    final rows = await db.rawQuery('PRAGMA user_version');
    await db.close();
    return rows.first;
  }

  test('v1 空库：5 张表 + user_version = 1', () async {
    final path = dbPath();
    final db = await Db.open(path);
    final tables = (await db.listNotebooks()).isEmpty &&
        (await db.loadSettings()).dailyGoal == 2000;
    expect(tables, isTrue);
    await db.close();
    final v = await userVersion(path);
    expect(v['user_version'], 1);
    // 表清单
    final conn = await databaseFactory.openDatabase(path);
    final rows = await conn.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    final names = rows.map((r) => r['name']).toList();
    expect(names, containsAll(['notebooks', 'documents', 'settings', 'stats', 'last_open']));
    await conn.close();
  });

  test('迁移链回放：v1 空库逐级升到 v2，数据无损', () async {
    final path = dbPath();
    // 1. 建 v1 库并写入数据
    final db1 = await Db.open(path);
    final nb = await db1.createNotebook('书');
    final doc = await db1.createDocument(nb.id, title: '第一章', content: '[{"insert":"正文"}]');
    await db1.saveDocument(id: doc.id, title: doc.title, content: '[{"insert":"正文内容"}]');
    await db1.setSetting('theme', 'dark');
    await db1.close();

    // 2. 升到 v2：加一列 + 回填
    final migrations = <SchemaMigration>[
      SchemaMigration(
        to: 2,
        up: (db) async {
          await db.execute('ALTER TABLE documents ADD COLUMN extra TEXT');
        },
      ),
    ];
    final db2 = await Db.open(path, version: 2, migrations: migrations);
    expect(await db2.listNotebooks(), hasLength(1));
    expect((await db2.listDocuments(nb.id)).single.title, '第一章');
    expect(await db2.todayDelta(), 2); // 保存增量 = 4 - 2（创建时已含「正文」2 字）
    expect(await db2.getSetting('theme'), 'dark');
    await db2.close();

    final v = await userVersion(path);
    expect(v['user_version'], 2);

    // 列确实存在
    final conn = await databaseFactory.openDatabase(path);
    final cols = await conn.rawQuery('PRAGMA table_info(documents)');
    expect(cols.map((c) => c['name']), contains('extra'));
    await conn.close();

    // 3. 升级前备份存在
    expect(File('$path.bak').existsSync(), isTrue);
  });

  test('迁移失败：抛可恢复错误 + 备份可恢复 + 库保持旧版本可重试', () async {
    final path = dbPath();
    final db1 = await Db.open(path);
    final nb = await db1.createNotebook('书');
    await db1.createDocument(nb.id, title: '第一章');
    await db1.close();
    final before = await File(path).readAsBytes();

    final broken = <SchemaMigration>[
      SchemaMigration(to: 2, up: (_) async => throw StateError('boom')),
    ];
    // 迁移失败 → open 抛 LibraryException
    await expectLater(
      Db.open(path, version: 2, migrations: broken),
      throwsA(isA<LibraryException>()),
    );

    // 备份已生成（升级前备份）
    expect(File('$path.bak').existsSync(), isTrue);

    // 库文件未损坏：仍是 v1，数据在
    final v = await userVersion(path);
    expect(v['user_version'], 1);
    final db3 = await Db.open(path);
    expect((await db3.listNotebooks()).single.name, '书');
    await db3.close();

    // 换正确迁移可重试成功
    final good = <SchemaMigration>[
      SchemaMigration(to: 2, up: (db) async => db.execute('ALTER TABLE documents ADD COLUMN extra TEXT')),
    ];
    final db4 = await Db.open(path, version: 2, migrations: good);
    expect((await db4.listNotebooks()).single.name, '书');
    await db4.close();
    expect((await userVersion(path))['user_version'], 2);

    // 失败前的字节内容与升级前一致 → .bak 是 v1 全量
    final bakBytes = await File('$path.bak').readAsBytes();
    expect(bakBytes, before);
  });

  test('备份滚动：保留最近 3 份', () async {
    final path = dbPath();

    // 每次重建一个干净的 v1 库；只删主库文件，保留已有备份（测试滚动链）。
    Future<void> resetToV1() async {
      final dbFile = File(path);
      if (await dbFile.exists()) await dbFile.delete();
      final db = await Db.open(path);
      await db.createNotebook('重置');
      await db.close();
    }

    Future<void> bumpTo(int v) async {
      final db = await Db.open(
        path,
        version: v,
        migrations: [
          for (var i = 2; i <= v; i++)
            SchemaMigration(to: i, up: (db) async => db.execute('ALTER TABLE documents ADD COLUMN c$i TEXT')),
        ],
      );
      await db.close();
    }

    await resetToV1();
    await bumpTo(2); // 升级 v1→v2，生成 .bak = v1
    await resetToV1();
    await bumpTo(3); // v2→v3：.bak = 新 v1, .bak.1 = 旧 v1
    await resetToV1();
    await bumpTo(4); // v3→v4：.bak/.bak.1/.bak.2 三份

    expect(File('$path.bak').existsSync(), isTrue);
    expect(File('$path.bak.1').existsSync(), isTrue);
    expect(File('$path.bak.2').existsSync(), isTrue);
    expect(File('$path.bak.3').existsSync(), isFalse);
  });
}
