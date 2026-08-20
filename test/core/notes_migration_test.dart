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
  late Db db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_notes');
    db = await Db.open('${tempDir.path}/test.db');
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  group('schema v4 迁移 (documents.notes)', () {
    test('新库 documents 有 notes 列，默认空串', () async {
      final nb = await db.createNotebook('书');
      final d1 = await db.createDocument(nb.id, title: '一');
      expect(d1.notes, '');
    });

    test('setDocumentNotes 保存并读取', () async {
      final nb = await db.createNotebook('书');
      final d1 = await db.createDocument(nb.id, title: '一');
      await db.setDocumentNotes(d1.id, '本章目的：引出主角\n出场：林渊、陆云');
      final reloaded = await db.getDocument(d1.id);
      expect(reloaded!.notes, '本章目的：引出主角\n出场：林渊、陆云');
    });

    test('setDocumentNotes 不存在的文档抛异常', () async {
      expect(
        () => db.setDocumentNotes('nope', '备注'),
        throwsA(isA<LibraryException>()),
      );
    });

    test('从 v3 迁移到 v4：notes 列添加，旧文档默认空串', () async {
      await db.close();
      final v3Path = '${tempDir.path}/v3.db';
      var v3db = await Db.open(v3Path, version: 3);
      final nb = await v3db.createNotebook('书');
      await v3db.createDocument(nb.id, title: '旧文档');
      await v3db.close();
      // 以 v4 打开触发迁移
      db = await Db.open(v3Path, version: 4);
      final docs = await db.listDocuments(nb.id);
      expect(docs.length, 1);
      expect(docs.first.notes, '');
      // 迁移后可正常写入备注
      await db.setDocumentNotes(docs.first.id, '迁移后的备注');
      final reloaded = await db.getDocument(docs.first.id);
      expect(reloaded!.notes, '迁移后的备注');
    });
  });
}
