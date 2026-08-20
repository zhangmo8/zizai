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

    test('全部阿拉伯数字编号 → 递增', () {
      expect(suggestedChapterTitle([doc('第 1 章'), doc('第 2 章')]), '第 3 章');
    });

    test('非连续编号 → 取最大值 +1', () {
      expect(suggestedChapterTitle([doc('第 1 章'), doc('第 5 章')]), '第 6 章');
    });

    test('全部中文数字编号 → 递增中文', () {
      expect(suggestedChapterTitle([doc('第一章'), doc('第二章')]), '第三章');
    });

    test('中文数字到十', () {
      expect(
        suggestedChapterTitle([
          doc('第八章'), doc('第九章'),
        ]),
        '第十章',
      );
    });

    test('中文数字到十一', () {
      expect(
        suggestedChapterTitle([
          doc('第九章'), doc('第十章'),
        ]),
        '第十一章',
      );
    });

    test('混合编号（中文+阿拉伯）→ 阿拉伯递增', () {
      expect(
        suggestedChapterTitle([doc('第一章'), doc('第 2 章')]),
        '第 3 章',
      );
    });

    test('有不符编号模式的标题 → 新章节', () {
      expect(
        suggestedChapterTitle([doc('第 1 章'), doc('序章')]),
        '新章节',
      );
    });

    test('有不符编号模式的标题2 → 新章节', () {
      expect(
        suggestedChapterTitle([doc('番外一'), doc('番外二')]),
        '新章节',
      );
    });

    test('全角数字编号 → 递增', () {
      expect(
        suggestedChapterTitle([doc('第１章'), doc('第２章')]),
        '第 3 章',
      );
    });

    test('带后缀标题仍能识别编号', () {
      expect(
        suggestedChapterTitle([doc('第 1 章 开端'), doc('第 2 章 相遇')]),
        '第 3 章',
      );
    });

    test('中文数字百', () {
      expect(
        suggestedChapterTitle([doc('第九十九章')]),
        '第一百章',
      );
    });
  });
}
