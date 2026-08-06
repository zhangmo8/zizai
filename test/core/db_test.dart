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
    tempDir = await Directory.systemTemp.createTemp('zizai_db_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<Db> openDb() => Db.open('${tempDir.path}/test.db');

  group('笔记本 CRUD', () {
    test('创建/列出按 position 排序', () async {
      final db = await openDb();
      final a = await db.createNotebook('第一本');
      final b = await db.createNotebook('第二本');
      final c = await db.createNotebook('第三本');
      expect(await db.listNotebooks(), [a, b, c]);
      await db.close();
    });

    test('重命名', () async {
      final db = await openDb();
      final a = await db.createNotebook('旧名');
      await db.renameNotebook(a.id, '新名');
      expect((await db.listNotebooks()).single.name, '新名');
      await db.close();
    });

    test('上移/下移交换 position', () async {
      final db = await openDb();
      final a = await db.createNotebook('A');
      final b = await db.createNotebook('B');
      final c = await db.createNotebook('C');
      await db.moveNotebook(c.id, up: true);
      expect((await db.listNotebooks()).map((n) => n.name), ['A', 'C', 'B']);
      await db.moveNotebook(a.id, up: true); // 已到顶部，no-op
      expect((await db.listNotebooks()).map((n) => n.name), ['A', 'C', 'B']);
      await db.moveNotebook(a.id, up: false);
      expect((await db.listNotebooks()).map((n) => n.name), ['C', 'A', 'B']);
      await db.moveNotebook(b.id, up: true);
      expect((await db.listNotebooks()).map((n) => n.name), ['C', 'B', 'A']);
      await db.close();
    });

    test('删除不存在的笔记本抛 LibraryException', () async {
      final db = await openDb();
      expect(() => db.deleteNotebook('nope'), throwsA(isA<LibraryException>()));
      await db.close();
    });
  });

  group('文档 CRUD', () {
    test('创建/列出按 position 排序，默认标题与空内容', () async {
      final db = await openDb();
      final nb = await db.createNotebook('书');
      final d1 = await db.createDocument(nb.id);
      final d2 = await db.createDocument(nb.id, title: '第二章', content: '[{"insert":"正文"}]');
      expect(d1.title, '未命名');
      expect(d1.words, 0);
      expect(await db.listDocuments(nb.id), [d1, d2]);
      expect((await db.getDocument(d1.id))!.content, '{}');
      await db.close();
    });

    test('getDocument 不存在返回 null', () async {
      final db = await openDb();
      expect(await db.getDocument('nope'), isNull);
      await db.close();
    });

    test('重命名文档', () async {
      final db = await openDb();
      final nb = await db.createNotebook('书');
      final d = await db.createDocument(nb.id);
      await db.renameDocument(d.id, '新章节');
      expect((await db.getDocument(d.id))!.title, '新章节');
      await db.close();
    });

    test('删除文档', () async {
      final db = await openDb();
      final nb = await db.createNotebook('书');
      final d = await db.createDocument(nb.id);
      await db.deleteDocument(d.id);
      expect(await db.getDocument(d.id), isNull);
      await db.close();
    });

    test('删除笔记本级联删除文档', () async {
      final db = await openDb();
      final nb = await db.createNotebook('书');
      final d = await db.createDocument(nb.id);
      await db.deleteNotebook(nb.id);
      expect(await db.getDocument(d.id), isNull);
      await db.close();
    });

    test('文档上移/下移仅在本笔记本内', () async {
      final db = await openDb();
      final nb1 = await db.createNotebook('书一');
      final nb2 = await db.createNotebook('书二');
      final a = await db.createDocument(nb1.id, title: 'A');
      final b = await db.createDocument(nb1.id, title: 'B');
      await db.createDocument(nb2.id, title: 'X');
      await db.moveDocument(b.id, up: true);
      expect((await db.listDocuments(nb1.id)).map((d) => d.title), ['B', 'A']);
      expect((await db.listDocuments(nb2.id)).map((d) => d.title), ['X']);
      await db.moveDocument(b.id, up: true); // 边界 no-op
      expect((await db.listDocuments(nb1.id)).map((d) => d.title), ['B', 'A']);
      // 移到末尾
      await db.moveDocument(a.id, up: false);
      expect((await db.listDocuments(nb1.id)).map((d) => d.title), ['B', 'A']);
      await db.close();
    });
  });

  group('saveDocument 增量', () {
    test('新增字数返回正增量并累计当日', () async {
      final db = await openDb();
      final nb = await db.createNotebook('书');
      final d = await db.createDocument(nb.id);
      final delta1 = await db.saveDocument(id: d.id, title: d.title, content: '[{"insert":"你好世界"}]');
      expect(delta1, 4);
      expect((await db.getDocument(d.id))!.words, 4);
      expect(await db.todayDelta(), 4);
      final delta2 = await db.saveDocument(id: d.id, title: d.title, content: '[{"insert":"你好世界 Hello"}]');
      expect(delta2, 1); // 5 - 4
      expect(await db.todayDelta(), 5);
      await db.close();
    });

    test('删除文字产生负增量，当日不下探到 0 以下', () async {
      final db = await openDb();
      final nb = await db.createNotebook('书');
      final d = await db.createDocument(nb.id);
      await db.saveDocument(id: d.id, title: d.title, content: '[{"insert":"一二三四五六"}]');
      expect(await db.todayDelta(), 6);
      final delta = await db.saveDocument(id: d.id, title: d.title, content: '[{"insert":""}]');
      expect(delta, -6);
      expect(await db.todayDelta(), 0); // 不下探
      // 继续负增量也保持 0
      await db.saveDocument(id: d.id, title: d.title, content: '[{"insert":""}]');
      expect(await db.todayDelta(), 0);
      await db.close();
    });

    test('保存时同步 last_open 快照', () async {
      final db = await openDb();
      final nb = await db.createNotebook('书');
      final d = await db.createDocument(nb.id);
      await db.saveDocument(id: d.id, title: d.title, content: '[{"insert":"五十"}]');
      final lo = await db.loadLastOpen();
      expect(lo!.documentId, d.id);
      expect(lo.notebookId, nb.id);
      expect(lo.words, 2);
      await db.close();
    });

    test('跨日增量按日期键分别累计（注入时钟）', () async {
      var fakeNow = DateTime(2026, 8, 1, 10, 0);
      final db = await Db.open('${tempDir.path}/test.db', clock: () => fakeNow);
      final nb = await db.createNotebook('书');
      final d = await db.createDocument(nb.id);
      await db.saveDocument(id: d.id, title: d.title, content: '[{"insert":"六字内容一二"}]'); // 6 字
      // 8/1 当天
      expect(await db.todayDelta(), 6);
      // 第二天：新增 1 词（ab）
      fakeNow = DateTime(2026, 8, 2, 9, 0);
      await db.saveDocument(id: d.id, title: d.title, content: '[{"insert":"六字内容一二ab"}]'); // +1
      expect(await db.todayDelta(), 1);
      // 8/1 的增量独立保留
      final day1 = await db.todayDelta(nowMs: DateTime(2026, 8, 1, 23, 0).millisecondsSinceEpoch);
      expect(day1, 6);
      await db.close();
    });

    test('跨日删字：当日扣减不下探到 0，不影响其他日期', () async {
      var fakeNow = DateTime(2026, 8, 3, 10, 0);
      final db = await Db.open('${tempDir.path}/test.db', clock: () => fakeNow);
      final nb = await db.createNotebook('书');
      final d = await db.createDocument(nb.id);
      await db.saveDocument(id: d.id, title: d.title, content: '[{"insert":"一二三四五六"}]');
      fakeNow = DateTime(2026, 8, 4, 10, 0);
      // 8/4 删 4 字：当天从 0 开始 → 扣减不下探，保持 0
      final delta = await db.saveDocument(id: d.id, title: d.title, content: '[{"insert":"一二"}]');
      expect(delta, -4);
      expect(await db.todayDelta(), 0);
      // 8/3 的 6 字不动
      final day3 = await db.todayDelta(nowMs: DateTime(2026, 8, 3, 12).millisecondsSinceEpoch);
      expect(day3, 6);
      await db.close();
    });

    test('保存不存在文档抛 LibraryException', () async {
      final db = await openDb();
      await expectLater(
        db.saveDocument(id: 'nope', title: 'x', content: '{}'),
        throwsA(isA<LibraryException>()),
      );
      await db.close();
    });

    test('非法 Delta 内容抛 LibraryException', () async {
      final db = await openDb();
      final nb = await db.createNotebook('书');
      final d = await db.createDocument(nb.id);
      await expectLater(
        db.saveDocument(id: d.id, title: d.title, content: '{"not":"delta"}'),
        throwsA(isA<LibraryException>()),
      );
      await db.close();
    });
  });

  group('settings', () {
    test('KV 读写与替换', () async {
      final db = await openDb();
      expect(await db.getSetting('theme'), isNull);
      await db.setSetting('theme', 'dark');
      await db.setSetting('fontSize', '20');
      expect(await db.getSetting('theme'), 'dark');
      await db.setSetting('theme', 'light'); // replace
      expect(await db.getSetting('theme'), 'light');
      await db.close();
    });

    test('损坏的 settings 值回退默认', () async {
      final db = await openDb();
      await db.setSetting('theme', 'not-a-theme');
      await db.setSetting('fontSize', 'abc');
      await db.setSetting('lineHeight', 'xyz');
      await db.setSetting('dailyGoal', '-999');
      final s = await db.loadSettings();
      expect(s.theme, 'system'); // 非法值回退默认
      expect(s.fontSize, 18);
      expect(s.lineHeight, 1.8);
      expect(s.dailyGoal, 100); // -999 钳制到下限 100
      await db.close();
    });

    test('loadSettings 默认值 / saveSettings 持久化', () async {
      final db = await openDb();
      final s = await db.loadSettings();
      expect(s.theme, 'system');
      expect(s.fontSize, 18);
      expect(s.lineHeight, 1.8);
      expect(s.dailyGoal, 2000);
      await db.saveSettings(const Settings(
        theme: 'dark',
        fontFamily: 'PingFang SC',
        fontSize: 22,
        lineHeight: 2.0,
        dailyGoal: 5000,
      ));
      final s2 = await db.loadSettings();
      expect(s2.theme, 'dark');
      expect(s2.fontFamily, 'PingFang SC');
      expect(s2.fontSize, 22);
      expect(s2.lineHeight, 2.0);
      expect(s2.dailyGoal, 5000);
      await db.close();
    });
  });

  group('last_open', () {
    test('读写', () async {
      final db = await openDb();
      expect(await db.loadLastOpen(), isNull);
      await db.saveLastOpen(notebookId: 'nb1', documentId: 'doc1', words: 100);
      final lo = await db.loadLastOpen();
      expect(lo!.notebookId, 'nb1');
      expect(lo.documentId, 'doc1');
      expect(lo.words, 100);
      await db.close();
    });
  });

  group('打开失败', () {
    test('无效路径抛可恢复 LibraryException', () async {
      final db = await openDb();
      await db.close();
      // 用目录路径当 db 文件 → 打开失败
      await expectLater(
        Db.open(tempDir.path),
        throwsA(isA<LibraryException>()),
      );
    });
  });
}
