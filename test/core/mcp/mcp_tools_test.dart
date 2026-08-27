import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/export.dart' show deltaToPlainText;
import 'package:zi_zai/core/mcp/mcp_tools.dart';
import 'package:zi_zai/core/snapshot_history.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Db db;
  late SnapshotHistory snapshots;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zizai_mcp_tools');
    db = await Db.open(inMemoryDatabasePath);
    snapshots = SnapshotHistory(rootPath: '${tmp.path}/snapshots');
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  List<ZizaiMcpTool> tools() => buildZizaiMcpTools(db, snapshots: snapshots);

  Future<Map<String, dynamic>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final tool = tools().firstWhere((t) => t.name == name);
    final result = await tool.handler(args);
    expect(result.isError, isFalse, reason: result.content);
    return jsonDecode(result.content) as Map<String, dynamic>;
  }

  Future<(String, String)> seedBook({int docs = 2}) async {
    final nb = await db.createNotebook('小说');
    var firstId = '';
    for (var i = 1; i <= docs; i++) {
      final doc = await db.createDocument(
        nb.id,
        title: '第$i章',
        content: '[{"insert":"正文内容$i"}]',
      );
      if (i == 1) firstId = doc.id;
    }
    return (nb.id, firstId);
  }

  test('list_notebooks：返回书名/章节数/总字数', () async {
    final nb = await db.createNotebook('小说');
    await db.createDocument(nb.id, title: '第一章', content: '[{"insert":"一二三四五"}]');
    final r = await call('list_notebooks');
    final notebooks = r['notebooks'] as List;
    expect(notebooks, hasLength(1));
    expect((notebooks.first as Map)['name'], '小说');
    expect((notebooks.first as Map)['documentCount'], 1);
    expect((notebooks.first as Map)['totalWords'], 5);
  });

  test('list_documents：按序返回章节元数据', () async {
    final (nbId, _) = await seedBook();
    final r = await call('list_documents', {'notebookId': nbId});
    final docs = r['documents'] as List;
    expect(docs, hasLength(2));
    expect((docs.first as Map)['title'], '第1章');
    expect((docs.first as Map)['words'], greaterThan(0));
  });

  test('list_documents：缺 notebookId 报错', () async {
    final tool = tools().firstWhere((t) => t.name == 'list_documents');
    final result = await tool.handler(const {});
    expect(result.isError, isTrue);
  });

  test('read_document：全文纯文本 + 元数据', () async {
    final (_, docId) = await seedBook(docs: 1);
    final r = await call('read_document', {'documentId': docId});
    final doc = r['document'] as Map;
    expect(doc['plainText'], '正文内容1');
    expect(doc['words'], greaterThan(0));
    expect(doc['title'], '第1章');
  });

  test('read_document：不存在 id 报错', () async {
    final tool = tools().firstWhere((t) => t.name == 'read_document');
    final result = await tool.handler({'documentId': 'doc_missing'});
    expect(result.isError, isTrue);
  });

  test('search_documents：命中 + notebookId 过滤 + 片段', () async {
    final (nbId, _) = await seedBook(docs: 2);
    await db.createDocument(
      nbId,
      title: '第3章',
      content: '[{"insert":"关键伏笔出现"}]',
    );
    final r = await call('search_documents', {
      'query': '伏笔',
      'notebookId': nbId,
    });
    final hits = r['hits'] as List;
    expect(hits, hasLength(1));
    expect((hits.first as Map)['title'], '第3章');
    expect((hits.first as Map)['snippet'], contains('关键伏笔出现'));
  });

  test('create_document：建章并落库', () async {
    final (nbId, _) = await seedBook(docs: 0);
    final r = await call('create_document', {
      'notebookId': nbId,
      'title': '新章',
      'content': '开局一段话。',
    });
    final doc = await db.getDocument(r['documentId'] as String);
    expect(doc, isNotNull);
    expect(doc!.title, '新章');
    expect(deltaToPlainText(doc.content), '开局一段话。');
  });

  test('append_document：追加内容 + 自动留快照 + 字数更新', () async {
    final (_, docId) = await seedBook(docs: 1);
    final r = await call('append_document', {
      'documentId': docId,
      'content': '续写第二段。',
    });
    expect(r['appended'], '续写第二段。');
    final doc = await db.getDocument(docId);
    final text = deltaToPlainText(doc!.content);
    expect(text, contains('正文内容1'));
    expect(text, contains('续写第二段。'));
    // 追加前自动留底：旧内容可在版本历史找回。
    final snaps = await snapshots.list(docId);
    expect(snaps, isNotEmpty);
    expect(snaps.first.content, contains('正文内容1'));
    expect(doc.words, greaterThan(4));
  });

  test('append_document：缺参数/不存在 id 报错', () async {
    final tool = tools().firstWhere((t) => t.name == 'append_document');
    expect((await tool.handler(const {})).isError, isTrue);
    expect(
      (await tool.handler({'documentId': 'x', 'content': ''})).isError,
      isTrue,
    );
    expect(
      (await tool.handler({'documentId': 'doc_missing', 'content': 'abc'}))
          .isError,
      isTrue,
    );
  });

  test('写操作成功后触发 onWrite（create/append），读操作不触发', () async {
    var writes = 0;
    final withHook = buildZizaiMcpTools(
      db,
      snapshots: snapshots,
      onWrite: () async => writes++,
    );
    Future<void> run(String name, Map<String, Object?> args) async {
      final tool = withHook.firstWhere((t) => t.name == name);
      final r = await tool.handler(args);
      expect(r.isError, isFalse, reason: r.content);
    }

    final (nbId, docId) = await seedBook(docs: 1);
    await run('list_notebooks', const {}); // 读操作
    await run('read_document', {'documentId': docId}); // 读操作
    expect(writes, 0); // 读不触发刷新

    await run('create_document', {
      'notebookId': nbId,
      'title': '新章',
    });
    expect(writes, 1); // 建章触发刷新

    await run('append_document', {
      'documentId': docId,
      'content': '续写。',
    });
    expect(writes, 2); // 追章触发刷新
  });
}
