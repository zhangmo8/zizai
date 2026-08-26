import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/models.dart';
import 'package:zi_zai/ui/sidebar.dart' show suggestedChapterTitle;

Document doc(String title) => Document(
  id: title,
  notebookId: 'nb',
  title: title,
  content: '{}',
  words: 0,
  position: 0,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  group('suggestedChapterTitle', () {
    test('空笔记本 → 第 1 章', () {
      expect(suggestedChapterTitle([]), '第 1 章');
    });

    test('按整本章节数 +1（阿拉伯编号书）', () {
      expect(suggestedChapterTitle([doc('第 1 章'), doc('第 2 章')]), '第 3 章');
      expect(suggestedChapterTitle([doc('第 1 章'), doc('第 5 章')]), '第 3 章');
    });

    test('大章节数量（2000 章书）', () {
      expect(
        suggestedChapterTitle([for (var i = 1; i <= 1008; i++) doc('第 $i 章')]),
        '第 1009 章',
      );
    });

    test('标题不含数字也照算（不再出现「新章节」）', () {
      expect(suggestedChapterTitle([doc('第 1 章'), doc('序章')]), '第 3 章');
      expect(suggestedChapterTitle([doc('番外一'), doc('番外二')]), '第 3 章');
    });

    test('中文编号书 → 仍按整本章节数 +1（阿拉伯）', () {
      expect(suggestedChapterTitle([doc('第一章'), doc('第二章')]), '第 3 章');
      expect(suggestedChapterTitle([doc('第九章'), doc('第十章')]), '第 3 章');
    });

    test('混合编号 → 数量 +1', () {
      expect(
        suggestedChapterTitle([doc('第一章'), doc('第 2 章')]),
        '第 3 章',
      );
    });

    test('带后缀标题仍按数量 +1', () {
      expect(
        suggestedChapterTitle([doc('第 1 章 开端'), doc('第 2 章 相遇')]),
        '第 3 章',
      );
    });

    test('全角数字编号 → 数量 +1', () {
      expect(
        suggestedChapterTitle([doc('第１章'), doc('第２章')]),
        '第 3 章',
      );
    });
  });
}