/// 橙瓜码字导入器测试：合成橙瓜库（真实 schema + 脏数据怪癖）→ 导入映射验证。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/import_chenggua.dart';

/// 按真实橙瓜 schema 建一张测试库并灌入数据。
Future<void> seedChengguaDb(
  Database db, {
  bool includeDeleted = true,
}) async {
  await db.execute('''
CREATE TABLE book_category (
  client_uuid TEXT PRIMARY KEY,
  parent_client_uuid TEXT NOT NULL DEFAULT '',
  type INTEGER NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  summary TEXT,
  sorts TEXT,
  word_count INTEGER,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  version INTEGER NOT NULL,
  is_upload INTEGER DEFAULT 0,
  created_at INTEGER,
  updated_at INTEGER
)''');
  await db.execute('''
CREATE TABLE chapter_content (
  chapter_uuid TEXT PRIMARY KEY,
  volume_uuid TEXT,
  category_id TEXT NOT NULL,
  uid INTEGER NOT NULL,
  content TEXT,
  word_count INTEGER,
  version INTEGER NOT NULL,
  is_deleted INTEGER NOT NULL,
  is_upload INTEGER NOT NULL,
  created_at INTEGER,
  updated_at INTEGER
)''');

  final book = '82afe7ae-143f-4586-b953-f22849c5e276';
  final vStudents = 'f6463b42-dd0d-4c23-be6d-39c15ac5f8f2';
  final vChapter = '6208ee36-a250-44ce-ba10-fbdebf605a3b';
  final vThird = '4f301858-8840-46c3-b3c7-fa1ee7cf5667';
  final ch1 = '8b7be0ff-0d80-4f68-b8dc-b259b0791955'; // 土娃儿进城
  final ch2 = '1ed7102a-fad5-458f-953c-8907d54ce182'; // 城市生活的开端
  final ch3 = '05b886e9-bad3-40e4-8a91-5d65381c88d9'; // 第一章(牛马篇)
  final ch4 = '3f615374-d1e9-4fe1-be0c-11647e21a68c'; // 第一章(第三卷)
  final chDeleted = '52e86fec-ce17-4f71-a5bd-615baaaa4414'; // 已删除章节

  Future<void> cat(String uuid, String parent, int type, String title,
      String? sorts, int deleted) async {
    await db.insert('book_category', {
      'client_uuid': uuid,
      'parent_client_uuid': parent,
      'type': type,
      'title': title,
      'sorts': sorts,
      'is_deleted': deleted,
      'version': 1,
      'is_upload': 0,
      'created_at': 1666000000000,
      'updated_at': 1666000000000,
    });
  }

  await cat(book, '', 1, '牛马日记', '[${[vStudents, vChapter, vThird].map((e) => '"$e"').join(',')}]', 0);
  await cat(vStudents, book, 2, '学生时代', '[${[ch1, ch2].map((e) => '"$e"').join(',')}]', 0);
  await cat(vChapter, book, 2, '牛马篇', '["$ch3"]', 0);
  // 橙瓜怪癖：sorts 里同一章节出现两次 → 导入必须去重。
  await cat(vThird, book, 2, '第三卷', '["$ch4","$ch4"]', 0);
  await cat(ch1, vStudents, 3, '土娃儿进城', null, 0);
  await cat(ch2, vStudents, 3, '城市生活的开端', null, 0);
  await cat(ch3, vChapter, 3, '第一章', null, 0);
  await cat(ch4, vThird, 3, '第一章', null, 0);
  if (includeDeleted) {
    await cat(chDeleted, vChapter, 3, '第一章(已删)', null, 1);
    // 已删除的图书 → 整书跳过
    await cat('dead-book', '', 1, '已删书', null, 1);
  }

  Future<void> content(String uuid, String? vol, String bookId, String text,
      int deleted) async {
    await db.insert('chapter_content', {
      'chapter_uuid': uuid,
      'volume_uuid': vol,
      'category_id': bookId,
      'uid': 1,
      'content': text,
      'word_count': text.length,
      'version': 1,
      'is_deleted': deleted,
      'is_upload': 0,
      'created_at': 1666000000000,
      'updated_at': 1666000000000,
    });
  }

  // 段落以 \t 开头、段间空行分隔（与真实橙瓜内容一致）。
  await content(ch1, vStudents, book,
      '\t“你打算带瓜娃去县里上学？”\n\t一辆驶向县城的班车。\n\n\t小齐皓看着窗外。', 0);
  await content(ch2, vStudents, book, '\t“不努力就只能当废物。”', 0);
  await content(ch3, vChapter, book,
      '\t那是我的朋友，在武汉读博士。\n\n\t他带我去了一家小馆子。', 0);
  await content(ch4, vThird, book, '', 0);
  if (includeDeleted) {
    await content(chDeleted, vChapter, book, '\t已删除的内容', 1);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_chenggua_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<Db> openTarget(String name) => Db.open('${tempDir.path}/$name.db');

  Future<String> makeSource() async {
    final srcPath = '${tempDir.path}/source/chenggua.db';
    await Directory('${tempDir.path}/source').create(recursive: true);
    final db = await databaseFactory.openDatabase(srcPath);
    await seedChengguaDb(db);
    await db.close();
    return srcPath;
  }

  test('导入映射：图书/卷/章节 + 顺序 + 去重 + 跳过已删除 + 字数', () async {
    final target = await openTarget('target');
    final src = await makeSource();

    final result = await importChenggua(
      target,
      src,
      tempDir: Directory('${tempDir.path}/work'),
    );

    expect(result.notebooks, 1);
    expect(result.volumes, 3);
    expect(result.docs, 4); // 已删除章节与已删除图书不计入

    final nbs = await target.listNotebooks();
    expect(nbs.single.name, '牛马日记');

    final vols = await target.listAllVolumes();
    expect(vols.map((v) => v.name).toList(), ['学生时代', '牛马篇', '第三卷']);

    final docs = await target.listAllDocuments();
    expect(docs.length, 4);
    expect(
      docs.map((d) => '${d.title}#${d.volumeId}').toList(),
      [
        '土娃儿进城#${vols[0].id}',
        '城市生活的开端#${vols[0].id}',
        '第一章#${vols[1].id}',
        '第一章#${vols[2].id}',
      ],
    );

    // 字数按字在规则重算（中文字符 + 英文词），含标点不计。
    final ch1 = docs.first;
    expect(ch1.content, contains('你打算带瓜娃去县里上学'));
    expect(ch1.content, contains('小齐皓看着窗外'));
    expect(ch1.words, greaterThan(0));
    // 空章节保留为空文档。
    final empty = docs.last;
    expect(empty.content, '{}');
    expect(empty.words, 0);

    // 已删除的图书/章节都没有进来。
    expect((await target.listNotebooks()).length, 1);
    expect(
      (await target.listAllDocuments()).any((d) => d.title.contains('已删')),
      isFalse,
    );

    await target.close();
  });

  test('追加合并：已有库 + 二次导入，position 不与既有笔记本冲突', () async {
    final target = await openTarget('target');
    await target.createNotebook('我的书'); // 既有笔记本
    final src = await makeSource();

    final r1 = await importChenggua(
      target,
      src,
      tempDir: Directory('${tempDir.path}/work1'),
    );
    expect(r1.notebooks, 1);
    final r2 = await importChenggua(
      target,
      src,
      tempDir: Directory('${tempDir.path}/work2'),
    );
    expect(r2.notebooks, 1);

    final nbs = await target.listNotebooks();
    expect(nbs.length, 3); // 我的书 + 导入两次
    expect(nbs.map((n) => n.position).toList(), [0, 1, 2]);
    await target.close();
  });

  test('缺失文件抛可读异常', () async {
    final target = await openTarget('target');
    await expectLater(
      importChenggua(
        target,
        '${tempDir.path}/does-not-exist.db',
        tempDir: Directory('${tempDir.path}/work'),
      ),
      throwsA(isA<ChengguaException>()),
    );
    await target.close();
  });
}
