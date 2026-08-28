import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/book_search.dart';
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

  group('searchBook', () {
    test('空查询与纯空白查询返回空', () async {
      final notebooks = [nb('n1', '书')];
      final docs = [doc('d1', 'n1', '章', '内容')];
      expect(
        await searchBook(
          notebooks: notebooks,
          documentsOf: (_) => docs,
          query: '',
        ),
        isEmpty,
      );
      expect(
        await searchBook(
          notebooks: notebooks,
          documentsOf: (_) => docs,
          query: '  ',
        ),
        isEmpty,
      );
    });

    test('按章节分组，命中带定位偏移', () async {
      final notebooks = [nb('n1', '第一卷')];
      final docs = [
        doc('d1', 'n1', '第一章', '林渊推门而入。\\n林渊坐下。'),
        doc('d2', 'n1', '第二章', '没有那个名字。'),
      ];
      final groups = await searchBook(
        notebooks: notebooks,
        documentsOf: (id) => id == 'n1' ? docs : const [],
        query: '林渊',
      );
      expect(groups.length, 1);
      final group = groups.single;
      expect(group.documentId, 'd1');
      expect(group.documentTitle, '第一章');
      expect(group.notebookName, '第一卷');
      expect(group.totalMatches, 2);
      expect(group.hits.length, 2);
      expect(group.hits[0].offset, 0);
      expect(group.hits[1].offset, 8); // 「林渊推门而入。\n」后
      expect(group.hits[1].length, 2);
    });

    test('查询忽略首尾空白', () async {
      final groups = await searchBook(
        notebooks: [nb('n1', '书')],
        documentsOf: (_) => [doc('d1', 'n1', '章', '找到关键词了')],
        query: ' 关键词 ',
      );
      expect(groups.single.hits.single.offset, 2);
    });

    test('大小写不敏感', () async {
      final groups = await searchBook(
        notebooks: [nb('n1', '书')],
        documentsOf: (_) => [doc('d1', 'n1', '章', 'Hello World')],
        query: 'hello',
      );
      expect(groups.single.hits.length, 1);
    });

    test('预览片段：不跨行、命中词区间正确、截断加省略号', () async {
      final long = '前' * 30;
      final groups = await searchBook(
        notebooks: [nb('n1', '书')],
        documentsOf: (_) => [
          doc('d1', 'n1', '章', '第一行\\n$long目标词${'后' * 50}\\n第三行'),
        ],
        query: '目标词',
      );
      final hit = groups.single.hits.single;
      expect(hit.preview.contains('\n'), isFalse);
      expect(hit.preview.startsWith('…'), isTrue);
      expect(hit.preview.endsWith('…'), isTrue);
      expect(
        hit.preview.substring(hit.previewMatchStart, hit.previewMatchEnd),
        '目标词',
      );
    });

    test('单章命中数截断但 totalMatches 保留真实值', () async {
      final groups = await searchBook(
        notebooks: [nb('n1', '书')],
        documentsOf: (_) => [doc('d1', 'n1', '章', '词词词词词')],
        query: '词',
        maxHitsPerDocument: 3,
      );
      expect(groups.single.hits.length, 3);
      expect(groups.single.totalMatches, 5);
    });

    test('全书上限截断后停止搜索', () async {
      final groups = await searchBook(
        notebooks: [nb('n1', '书')],
        documentsOf: (_) => [
          doc('d1', 'n1', '一', '词词词'),
          doc('d2', 'n1', '二', '词词词'),
          doc('d3', 'n1', '三', '词'),
        ],
        query: '词',
        maxTotalHits: 4,
      );
      expect(groups.length, 2);
      expect(groups[0].hits.length, 3);
      expect(groups[1].hits.length, 1);
    });

    test('坏文档跳过，不阻塞全书搜索', () async {
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
      final groups = await searchBook(
        notebooks: [nb('n1', '书')],
        documentsOf: (_) => [bad, doc('d2', 'n1', '好', '有词的')],
        query: '词',
      );
      expect(groups.single.documentId, 'd2');
    });

    test('缓存失效：同 id 章节内容更新后必须反映新内容', () async {
      // 搜索缓存以 content 全等失效——保存后旧关键词必须不再命中、
      // 新关键词必须命中（不存在读到旧文本的路径）。
      final notebooks = [nb('n1', '书')];
      var text = '旧章节里有林渊';
      Document d() => doc('d1', 'n1', '第一章', text);

      expect(
        await searchBook(
          notebooks: notebooks,
          documentsOf: (_) => [d()],
          query: '林渊',
        ),
        isNotEmpty,
      );

      text = '新章节只有林小雨';
      expect(
        await searchBook(
          notebooks: notebooks,
          documentsOf: (_) => [d()],
          query: '林渊',
        ),
        isEmpty,
      );
      expect(
        await searchBook(
          notebooks: notebooks,
          documentsOf: (_) => [d()],
          query: '林小雨',
        ),
        isNotEmpty,
      );
    });

    test('章节顺序沿用侧边栏（笔记本序 + 文档序）', () async {
      final groups = await searchBook(
        notebooks: [nb('n1', '卷一'), nb('n2', '卷二')],
        documentsOf: (id) => id == 'n1'
            ? [doc('d1', 'n1', '一', '词')]
            : [doc('d2', 'n2', '二', '词')],
        query: '词',
      );
      expect(groups.map((g) => g.documentId).toList(), ['d1', 'd2']);
    });
  });
}
