import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/chapter_ops.dart';
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
    tempDir = await Directory.systemTemp.createTemp('zizai_chapter_ops');
    db = await Db.open('${tempDir.path}/test.db');
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  group('splitDocumentContent', () {
    test('在中间偏移拆分：前半段 + 后半段', () {
      const content = '[{"insert":"第一段内容\\n第二段内容\\n"}]';
      final result = splitDocumentContent(content, 5);
      // 前半段应该有 "第一段内容"（前5字符）
      expect(result.firstContent, contains('第一段'));
      // 后半段应该有 "内容" 之后的部分
      expect(result.secondContent, contains('第二段'));
    });

    test('偏移 0：前半段空，后半段全部', () {
      const content = '[{"insert":"一些文字\\n"}]';
      final result = splitDocumentContent(content, 0);
      expect(result.firstContent, '{}');
      expect(result.secondContent, contains('一些文字'));
    });

    test('偏移超出长度：前半段全部，后半段空', () {
      const content = '[{"insert":"短\\n"}]';
      final result = splitDocumentContent(content, 999);
      expect(result.firstContent, contains('短'));
      expect(result.secondContent, '{}');
    });

    test('空文档拆分：两段都空', () {
      final result = splitDocumentContent('{}', 0);
      expect(result.firstContent, '{}');
      expect(result.secondContent, '{}');
    });

    test('保留格式属性', () {
      const content = '[{"insert":"加粗"},{"insert":"普通","attributes":{"bold":true}},{"insert":"结尾\\n"}]';
      // 在 "加粗" 后（偏移 2）拆分
      final result = splitDocumentContent(content, 2);
      expect(result.firstContent, contains('加粗'));
      expect(result.secondContent, contains('普通'));
      expect(result.secondContent, contains('"bold"'));
    });
  });

  group('mergeDocumentContent', () {
    test('两段非空合并', () {
      const first = '[{"insert":"第一段\\n"}]';
      const second = '[{"insert":"第二段\\n"}]';
      final merged = mergeDocumentContent(first, second);
      expect(merged, contains('第一段'));
      expect(merged, contains('第二段'));
    });

    test('第一段空：返回第二段', () {
      const first = '{}';
      const second = '[{"insert":"内容\\n"}]';
      final merged = mergeDocumentContent(first, second);
      expect(merged, second);
    });

    test('第二段空：返回第一段', () {
      const first = '[{"insert":"内容\\n"}]';
      const second = '{}';
      final merged = mergeDocumentContent(first, second);
      expect(merged, first);
    });

    test('合并时确保段落分隔（第一段末尾补换行）', () {
      const first = '[{"insert":"无换行结尾"}]';
      const second = '[{"insert":"第二段\\n"}]';
      final merged = mergeDocumentContent(first, second);
      // 合并后应该有换行分隔
      expect(merged, contains('\\n'));
      expect(merged, contains('无换行结尾'));
      expect(merged, contains('第二段'));
    });
  });

  group('Db.reorderDocument', () {
    test('同笔记本内拖拽重排', () async {
      final nb = await db.createNotebook('书');
      await db.createDocument(nb.id, title: '一');
      await db.createDocument(nb.id, title: '二');
      final d3 = await db.createDocument(nb.id, title: '三');
      // 把 d3 移到 position 0
      await db.reorderDocument(d3.id, notebookId: nb.id, newPosition: 0);
      final docs = await db.listDocuments(nb.id);
      expect(docs.map((d) => d.title).toList(), ['三', '一', '二']);
    });

    test('拖到最后', () async {
      final nb = await db.createNotebook('书');
      final d1 = await db.createDocument(nb.id, title: '一');
      await db.createDocument(nb.id, title: '二');
      await db.createDocument(nb.id, title: '三');
      // 把 d1 移到最后
      await db.reorderDocument(d1.id, notebookId: nb.id, newPosition: 2);
      final docs = await db.listDocuments(nb.id);
      expect(docs.map((d) => d.title).toList(), ['二', '三', '一']);
    });

    test('position 连续无空洞', () async {
      final nb = await db.createNotebook('书');
      final d1 = await db.createDocument(nb.id, title: '一');
      await db.createDocument(nb.id, title: '二');
      await db.createDocument(nb.id, title: '三');
      await db.reorderDocument(d1.id, notebookId: nb.id, newPosition: 2);
      final docs = await db.listDocuments(nb.id);
      for (var i = 0; i < docs.length; i++) {
        expect(docs[i].position, i);
      }
    });

    test('跨笔记本移动', () async {
      final nb1 = await db.createNotebook('书一');
      final nb2 = await db.createNotebook('书二');
      final d1 = await db.createDocument(nb1.id, title: '一');
      await db.createDocument(nb1.id, title: '二');
      await db.createDocument(nb2.id, title: '三');
      // 把 d1 从 nb1 移到 nb2 的 position 0
      await db.reorderDocument(d1.id, notebookId: nb2.id, newPosition: 0);
      final docs1 = await db.listDocuments(nb1.id);
      final docs2 = await db.listDocuments(nb2.id);
      expect(docs1.map((d) => d.title).toList(), ['二']);
      expect(docs2.map((d) => d.title).toList(), ['一', '三']);
    });
  });

  group('Db.duplicateDocument', () {
    test('创建副本：标题加「副本」后缀，内容相同', () async {
      final nb = await db.createNotebook('书');
      final d1 = await db.createDocument(nb.id, title: '一章');
      await db.saveDocument(
        id: d1.id,
        title: '一章',
        content: '[{"insert":"内容\\n"}]',
      );
      final copy = await db.duplicateDocument(d1.id);
      expect(copy.title, '一章 副本');
      expect(copy.content, '[{"insert":"内容\\n"}]');
      expect(copy.notebookId, nb.id);
    });

    test('副本 position 紧跟原文档', () async {
      final nb = await db.createNotebook('书');
      final d1 = await db.createDocument(nb.id, title: '一');
      await db.createDocument(nb.id, title: '二');
      final copy = await db.duplicateDocument(d1.id);
      expect(copy.position, 1); // d1 在 0，副本在 1
      final docs = await db.listDocuments(nb.id);
      expect(docs.map((d) => d.title).toList(), ['一', '一 副本', '二']);
    });

    test('复制后 position 无空洞', () async {
      final nb = await db.createNotebook('书');
      final d1 = await db.createDocument(nb.id, title: '一');
      await db.createDocument(nb.id, title: '二');
      await db.createDocument(nb.id, title: '三');
      await db.duplicateDocument(d1.id);
      final docs = await db.listDocuments(nb.id);
      for (var i = 0; i < docs.length; i++) {
        expect(docs[i].position, i);
      }
    });
  });

  group('Db.setDocumentStatus', () {
    test('设置状态并持久化', () async {
      final nb = await db.createNotebook('书');
      final d1 = await db.createDocument(nb.id, title: '一');
      expect(d1.status, DocumentStatus.draft);
      await db.setDocumentStatus(d1.id, DocumentStatus.done);
      final reloaded = await db.getDocument(d1.id);
      expect(reloaded!.status, DocumentStatus.done);
    });

    test('不存在的文档抛异常', () async {
      expect(
        () => db.setDocumentStatus('nope', DocumentStatus.done),
        throwsA(isA<LibraryException>()),
      );
    });
  });

  group('DocumentStatus', () {
    test('fromString 正确映射', () {
      expect(DocumentStatus.fromString('draft'), DocumentStatus.draft);
      expect(DocumentStatus.fromString('done'), DocumentStatus.done);
      expect(DocumentStatus.fromString('todo'), DocumentStatus.todo);
      // 未知值回退 draft
      expect(DocumentStatus.fromString('unknown'), DocumentStatus.draft);
      expect(DocumentStatus.fromString(''), DocumentStatus.draft);
    });

    test('label 中文标签', () {
      expect(DocumentStatus.draft.label, '草稿');
      expect(DocumentStatus.done.label, '完成');
      expect(DocumentStatus.todo.label, '待修改');
    });
  });

  group('schema v3 迁移', () {
    test('新库 documents 表有 status 列，默认 draft', () async {
      final nb = await db.createNotebook('书');
      final d1 = await db.createDocument(nb.id, title: '一');
      expect(d1.status, DocumentStatus.draft);
    });

    test('从 v2 迁移到 v3：status 列添加，旧文档默认 draft', () async {
      // 先以 v2 打开
      await db.close();
      final v2Path = '${tempDir.path}/v2.db';
      var v2db = await Db.open(v2Path, version: 2);
      final nb = await v2db.createNotebook('书');
      await v2db.createDocument(nb.id, title: '旧文档');
      await v2db.close();
      // 再以 v3 打开（触发迁移）
      db = await Db.open(v2Path, version: 3);
      final docs = await db.listDocuments(nb.id);
      expect(docs.length, 1);
      expect(docs.first.status, DocumentStatus.draft);
    });
  });
}
