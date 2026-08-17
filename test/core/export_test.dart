import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/export.dart';
import 'package:zi_zai/core/models.dart';

void main() {
  group('deltaToPlainText', () {
    test('空文档占位返回空串', () {
      expect(deltaToPlainText(''), '');
      expect(deltaToPlainText('{}'), '');
    });

    test('简单插入', () {
      expect(deltaToPlainText('[{"insert":"你好世界"}]'), '你好世界');
    });

    test('带格式属性', () {
      expect(
        deltaToPlainText('[{"insert":"加粗"},{"insert":"普通","attributes":{"bold":true}}]'),
        '加粗普通',
      );
    });

    test('换行', () {
      expect(deltaToPlainText('[{"insert":"第一行\\n第二行"}]'), '第一行\n第二行');
    });

    test('非法结构抛 FormatException', () {
      expect(() => deltaToPlainText('{"a":1}'), throwsFormatException);
      expect(() => deltaToPlainText('不是json'), throwsFormatException);
      expect(() => deltaToPlainText('[42]'), throwsFormatException); // op 非对象
      expect(() => deltaToPlainText('[{"delete":1}]'), throwsFormatException); // 缺 insert
    });
  });

  group('exportPlainText', () {
    test('文档导出纯文本', () {
      const doc = Document(
        id: 'd1',
        notebookId: 'n1',
        title: 't',
        content: '[{"insert":"导出的内容"}]',
        words: 5,
        position: 0,
        createdAt: 0,
        updatedAt: 0,
      );
      expect(exportPlainText(doc), '导出的内容');
    });
  });

  Notebook nb(String id, String name, int position) => Notebook(
    id: id,
    name: name,
    position: position,
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

  group('chapterHeading', () {
    test('自动编号并清理旧版 .md 扩展名', () {
      expect(chapterHeading('楔子.md', number: 1), '第 1 章 楔子');
      expect(chapterHeading('  相遇 ', number: 12), '第 12 章 相遇');
    });

    test('标题已带编号则不重复加', () {
      expect(chapterHeading('第一章 相遇', number: 3), '第一章 相遇');
      expect(chapterHeading('第12章 重逢', number: 3), '第12章 重逢');
      expect(chapterHeading('第 三 回 惊变', number: 3), '第 三 回 惊变');
    });

    test('不编号时原样返回', () {
      expect(chapterHeading('尾声', number: null), '尾声');
      expect(chapterHeading('', number: null), '未命名');
    });
  });

  group('exportBookPlainText', () {
    test('单笔记本：无卷名，章节连续编号 + 段间空行', () {
      final text = exportBookPlainText(
        [nb('n1', '我的书', 0)],
        [
          doc('d1', 'n1', '开端', '第一段\\n第二段'),
          doc('d2', 'n1', '发展', '正文'),
        ],
      );
      expect(text, '第 1 章 开端\n\n第一段\n\n第二段\n\n第 2 章 发展\n\n正文\n');
    });

    test('多笔记本：输出卷名，编号跨卷连续', () {
      final text = exportBookPlainText(
        [nb('n1', '第一卷', 0), nb('n2', '第二卷', 1)],
        [
          doc('d1', 'n1', '开端', 'A'),
          doc('d2', 'n2', '再起', 'B'),
        ],
      );
      expect(text.contains('第一卷'), isTrue);
      expect(text.contains('第 1 章 开端'), isTrue);
      expect(text.contains('第二卷'), isTrue);
      expect(text.contains('第 2 章 再起'), isTrue);
    });

    test('段首缩进 + 不空行选项', () {
      final text = exportBookPlainText(
        [nb('n1', '书', 0)],
        [doc('d1', 'n1', '章', '一段\\n二段')],
        options: const BookExportOptions(
          numberChapters: false,
          indentParagraphs: true,
          blankLineBetweenParagraphs: false,
        ),
      );
      expect(text, '章\n\n　　一段\n　　二段\n');
    });

    test('空库返回空串', () {
      expect(exportBookPlainText(const [], const []), '');
    });
  });

  group('exportBookMarkdown', () {
    test('单卷：章 = 一级标题；缩进选项被忽略', () {
      final text = exportBookMarkdown(
        [nb('n1', '书', 0)],
        [doc('d1', 'n1', '开端', '正文')],
        options: const BookExportOptions(indentParagraphs: true),
      );
      expect(text, '# 第 1 章 开端\n\n正文\n');
    });

    test('多卷：卷 = #，章 = ##', () {
      final text = exportBookMarkdown(
        [nb('n1', '第一卷', 0), nb('n2', '第二卷', 1)],
        [doc('d1', 'n1', '开端', 'A'), doc('d2', 'n2', '再起', 'B')],
      );
      expect(text.contains('# 第一卷'), isTrue);
      expect(text.contains('## 第 1 章 开端'), isTrue);
      expect(text.contains('## 第 2 章 再起'), isTrue);
    });
  });

  group('exportBookMarkdownFiles', () {
    test('每章一文件：序号前缀保证目录顺序，标题入文件名', () {
      final files = exportBookMarkdownFiles(
        [nb('n1', '书', 0)],
        [
          doc('d1', 'n1', '开端', 'A'),
          doc('d2', 'n1', '发展?', 'B'),
        ],
      );
      expect(files.length, 2);
      expect(files[0].fileName, '001 第 1 章 开端.md');
      expect(files[0].content, '# 第 1 章 开端\n\nA\n');
      // 保留字符替换为空格后压缩
      expect(files[1].fileName, '002 第 2 章 发展.md');
    });
  });

  group('safeFileName', () {
    test('替换保留字符并压缩空白', () {
      expect(safeFileName('a/b\\c:d*e?f"g<h>i|j'), 'a b c d e f g h i j');
      expect(safeFileName('  '), '未命名');
    });
  });
}
