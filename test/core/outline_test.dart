import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/outline.dart';

void main() {
  group('extractOutline', () {
    test('多级标题提取：文本/层级/偏移', () {
      // "第一章\n正文abc\n小节\n结尾\n"，第一章=H1、小节=H2
      final ops = [
        {'insert': '第一章'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
        {'insert': '正文abc\n小节'},
        {
          'insert': '\n',
          'attributes': {'header': 2},
        },
        {'insert': '结尾\n'},
      ];
      final outline = extractOutline(ops);
      expect(outline, const [
        OutlineEntry(text: '第一章', level: 1, offset: 0),
        OutlineEntry(text: '小节', level: 2, offset: 10),
      ]);
    });

    test('无标题 → 空列表', () {
      expect(
        extractOutline([
          {'insert': '只有正文\n两行\n'},
        ]),
        isEmpty,
      );
    });

    test('格式混排不影响偏移：行内 attributes + 多 op 同行', () {
      // "AB粗C\n标题\n"：标题行首偏移 = 5
      final ops = [
        {'insert': 'AB'},
        {
          'insert': '粗',
          'attributes': {'bold': true},
        },
        {'insert': 'C\n标题'},
        {
          'insert': '\n',
          'attributes': {'header': 3},
        },
      ];
      expect(extractOutline(ops), const [
        OutlineEntry(text: '标题', level: 3, offset: 5),
      ]);
    });

    test('embed 按 1 字符计入偏移', () {
      final ops = [
        {
          'insert': {'image': 'x.png'},
        },
        {'insert': '\n后标题'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
      ];
      expect(extractOutline(ops), const [
        OutlineEntry(text: '后标题', level: 1, offset: 2),
      ]);
    });

    test('header 超出 1-3 或非法值被忽略', () {
      final ops = [
        {'insert': 'x'},
        {
          'insert': '\n',
          'attributes': {'header': 4},
        },
        {'insert': 'y'},
        {
          'insert': '\n',
          'attributes': {'header': 'h1'},
        },
      ];
      expect(extractOutline(ops), isEmpty);
    });

    test('空标题行保留（文本为空串）', () {
      final ops = [
        {
          'insert': '\n',
          'attributes': {'header': 2},
        },
      ];
      expect(extractOutline(ops), const [
        OutlineEntry(text: '', level: 2, offset: 0),
      ]);
    });
  });
}
