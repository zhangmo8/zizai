import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/models.dart';
import 'package:zi_zai/core/word_distribution.dart';

Document _doc(String id, int position, int words, {String? title}) =>
    Document(
      id: id,
      notebookId: 'nb',
      title: title ?? '章节$id',
      content: '{}',
      words: words,
      position: position,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  test('按 position 升序输出（节奏图固定叙事正序）', () {
    final dist = buildWordDistribution([
      _doc('c', 2, 300),
      _doc('a', 0, 100),
      _doc('b', 1, 200),
    ]);
    expect(
      [for (final c in dist.chapters) c.id],
      ['a', 'b', 'c'],
    );
  });

  test('汇总：总字数 / 最长章 / 平均每章', () {
    final dist = buildWordDistribution([
      _doc('a', 0, 1000, title: '第一章'),
      _doc('b', 1, 2500, title: '第二章'),
      _doc('c', 2, 500, title: '第三章'),
    ]);
    expect(dist.count, 3);
    expect(dist.totalWords, 4000);
    expect(dist.maxWords, 2500);
    expect(dist.averageWords, 1333); // (1000+2500+500)/3 = 1333.33 → 1333
  });

  test('空书：count=0、average=0、maxWords=0', () {
    final dist = buildWordDistribution(const <Document>[]);
    expect(dist.chapters, isEmpty);
    expect(dist.count, 0);
    expect(dist.totalWords, 0);
    expect(dist.maxWords, 0);
    expect(dist.averageWords, 0);
  });

  test('全零字数：maxWords 保持 0（UI 不画条形）', () {
    final dist = buildWordDistribution([_doc('a', 0, 0), _doc('b', 1, 0)]);
    expect(dist.count, 2);
    expect(dist.totalWords, 0);
    expect(dist.maxWords, 0);
    expect(dist.averageWords, 0);
  });

  test('不改传入列表的顺序', () {
    final input = [_doc('c', 2, 300), _doc('a', 0, 100)];
    buildWordDistribution(input);
    expect(input.map((d) => d.id).toList(), ['c', 'a']);
  });
}
