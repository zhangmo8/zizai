import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/book_search.dart';
import 'package:zi_zai/core/export.dart' show parseDeltaOps;
import 'package:zi_zai/core/models.dart';

void main() {
  Notebook nb(String id, String name) => Notebook(
    id: id,
    name: name,
    position: 0,
    createdAt: 0,
    updatedAt: 0,
  );

  Document doc(String id, String notebookId, String title, String text) =>
      Document(
        id: id,
        notebookId: notebookId,
        title: title,
        content: '[{"insert":"$text"}]',
        words: 0,
        position: 0,
        createdAt: 0,
        updatedAt: 0,
      );

  group('replaceInDocument', () {
    test('替换全部匹配并返回新内容', () {
      final d = doc('d1', 'n1', '章', '林渊来了。林渊走了。');
      final result = replaceInDocument(
        document: d,
        query: '林渊',
        replacement: '陆云',
      );
      expect(result.replacedCount, 2);
      expect(result.newContent, contains('陆云'));
      expect(result.newContent, isNot(contains('林渊')));
    });

    test('无匹配返回原内容', () {
      final d = doc('d1', 'n1', '章', '没有关键词');
      final result = replaceInDocument(
        document: d,
        query: '不存在',
        replacement: '替换',
      );
      expect(result.replacedCount, 0);
      expect(result.newContent, d.content);
    });

    test('空查询返回原内容', () {
      final d = doc('d1', 'n1', '章', '一些文字');
      final result = replaceInDocument(
        document: d,
        query: '  ',
        replacement: '替换',
      );
      expect(result.replacedCount, 0);
      expect(result.newContent, d.content);
    });

    test('替换后 Delta 结构有效（含末尾换行）', () {
      final d = doc('d1', 'n1', '章', '找到关键词了');
      final result = replaceInDocument(
        document: d,
        query: '关键词',
        replacement: '新词',
      );
      expect(result.replacedCount, 1);
      // 应该是有效的 JSON 数组
      final decoded = result.newContent;
      expect(decoded.startsWith('['), isTrue);
      expect(decoded, contains('新词'));
    });

    test('保留 Delta 格式属性', () {
      // 带加粗格式的文本
      final d = Document(
        id: 'd1',
        notebookId: 'n1',
        title: '章',
        content: '[{"insert":"林渊"},{"insert":"加粗","attributes":{"bold":true}},{"insert":"来了"}]',
        words: 0,
        position: 0,
        createdAt: 0,
        updatedAt: 0,
      );
      final result = replaceInDocument(
        document: d,
        query: '林渊',
        replacement: '陆云',
      );
      expect(result.replacedCount, 1);
      expect(result.newContent, contains('陆云'));
      // 加粗属性应保留
      expect(result.newContent, contains('"bold":true'));
      expect(result.newContent, isNot(contains('林渊')));
    });

    test('非 JSON 正文按纯文本宽容处理，可替换不抛错', () {
      final bad = Document(
        id: 'bad',
        notebookId: 'n1',
        title: '坏',
        content: '不是json',
        words: 0,
        position: 0,
        createdAt: 0,
        updatedAt: 0,
      );
      final result = replaceInDocument(
        document: bad,
        query: 'json',
        replacement: 'JSON',
      );
      expect(result.replacedCount, 1);
      expect(result.newContent, contains('JSON'));
      // 替换产物是合法 Delta JSON。
      expect(() => parseDeltaOps(result.newContent), returnsNormally);
    });

    test('空文档返回原内容', () {
      final d = Document(
        id: 'd1',
        notebookId: 'n1',
        title: '空',
        content: '{}',
        words: 0,
        position: 0,
        createdAt: 0,
        updatedAt: 0,
      );
      final result = replaceInDocument(
        document: d,
        query: '词',
        replacement: '新',
      );
      expect(result.replacedCount, 0);
      expect(result.newContent, '{}');
    });
  });

  group('replaceAllInBook', () {
    test('跨文档替换并返回总数', () async {
      final notebooks = [nb('n1', '书')];
      final docs = [
        doc('d1', 'n1', '一', '林渊来了'),
        doc('d2', 'n1', '二', '没有那个人'),
        doc('d3', 'n1', '三', '林渊走了'),
      ];
      final saved = <String, String>{};
      final total = await replaceAllInBook(
        notebooks: notebooks,
        documentsOf: (id) => id == 'n1' ? docs : const [],
        query: '林渊',
        replacement: '陆云',
        saveDocument: ({
          required documentId,
          required title,
          required content,
        }) async {
          saved[documentId] = content;
        },
      );
      expect(total, 2); // d1 和 d3 各 1 处
      expect(saved.keys, containsAll(['d1', 'd3']));
      expect(saved['d1'], contains('陆云'));
      expect(saved['d3'], contains('陆云'));
      expect(saved.containsKey('d2'), isFalse); // 无匹配不保存
    });

    test('坏文档跳过不阻塞', () async {
      final bad = Document(
        id: 'bad',
        notebookId: 'n1',
        title: '坏',
        content: '不是json',
        words: 0,
        position: 0,
        createdAt: 0,
        updatedAt: 0,
      );
      final total = await replaceAllInBook(
        notebooks: [nb('n1', '书')],
        documentsOf: (_) => [bad, doc('d2', 'n1', '好', '有词的')],
        query: '词',
        replacement: '字',
        saveDocument: ({required documentId, required title, required content}) async {},
      );
      expect(total, 1);
    });

    test('空查询返回 0', () async {
      final total = await replaceAllInBook(
        notebooks: [nb('n1', '书')],
        documentsOf: (_) => [doc('d1', 'n1', '章', '文字')],
        query: '',
        replacement: '替换',
        saveDocument: ({required documentId, required title, required content}) async {},
      );
      expect(total, 0);
    });
  });

  group('previewReplaceInBook', () {
    test('生成替换预览：before → after', () async {
      final previews = await previewReplaceInBook(
        notebooks: [nb('n1', '书')],
        documentsOf: (_) => [doc('d1', 'n1', '章', '林渊来了。没有别人。')],
        query: '林渊',
        replacement: '陆云',
      );
      expect(previews.length, 1);
      final p = previews.single;
      expect(p.documentId, 'd1');
      expect(p.matchCount, 1);
      expect(p.replacements.length, 1);
      expect(p.replacements[0].before, contains('林渊'));
      expect(p.replacements[0].after, contains('陆云'));
      expect(p.replacements[0].after, isNot(contains('林渊')));
    });

    test('无匹配的文档不出现在预览中', () async {
      final previews = await previewReplaceInBook(
        notebooks: [nb('n1', '书')],
        documentsOf: (_) => [
          doc('d1', 'n1', '有', '有词'),
          doc('d2', 'n1', '无', '没有'),
        ],
        query: '词',
        replacement: '字',
      );
      expect(previews.length, 1);
      expect(previews.single.documentId, 'd1');
    });
  });
}
