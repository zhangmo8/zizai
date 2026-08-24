import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/ui/editor.dart' show bracketPairCorrection;

void main() {
  group('bracketPairCorrection 开括号补全', () {
    const cases = <(String, String)>[
      ('(', ')'),
      ('（', '）'),
      ('【', '】'),
      ('“', '”'),
      ('"', '"'),
      ('「', '」'),
      ('{', '}'),
    ];
    for (final (open, close) in cases) {
      test('$open → 补全 $close，光标在中间', () {
        final result = bracketPairCorrection('你好', 2, open);
        expect(result, isNotNull);
        final (text, cursor) = result!;
        expect(text, '你好$open$close');
        expect(cursor, 3); // 停在开闭之间
      });
    }

    test('空文档开头输入【 → 补全，光标在 1', () {
      final (text, cursor) = bracketPairCorrection('', 0, '【')!;
      expect(text, '【】');
      expect(cursor, 1);
    });

    test('文档中间插入（pos 非末尾）', () {
      final (text, cursor) = bracketPairCorrection('a b', 1, '（')!;
      expect(text, 'a（） b');
      expect(cursor, 2);
    });
  });

  group('bracketPairCorrection 闭括号跳过', () {
    test('补全对中间输入】 → 跳过，光标越过', () {
      final (text, cursor) = bracketPairCorrection('【】', 1, '】')!;
      expect(text, '【】');
      expect(cursor, 2);
    });

    test('有内容时中间输入】 → 跳过', () {
      final (text, cursor) = bracketPairCorrection('【内容】', 3, '】')!;
      expect(text, '【内容】');
      expect(cursor, 4);
    });

    test('英文引号对中间输入" → 跳过', () {
      final (text, cursor) = bracketPairCorrection('""', 1, '"')!;
      expect(text, '""');
      expect(cursor, 2);
    });

    test('光标后无闭括号时输入】 → 正常插入（不跳过）', () {
      expect(bracketPairCorrection('正文', 2, '】'), isNull);
      expect(bracketPairCorrection('】', 1, '】'), isNull); // 末尾追加
    });
  });

  group('bracketPairCorrection 无关字符', () {
    test('普通字符返回 null（走默认插入）', () {
      expect(bracketPairCorrection('你好', 2, 'a'), isNull);
      expect(bracketPairCorrection('你好', 2, '中'), isNull);
      expect(bracketPairCorrection('你好', 2, '。'), isNull);
    });

    test('非闭括号字符不与相邻字符混淆', () {
      // 「好」不是闭括号，即使前有「好」也不跳过。
      expect(bracketPairCorrection('好好', 1, '好'), isNull);
    });

    test('越界位置返回 null', () {
      expect(bracketPairCorrection('abc', -1, '('), isNull);
      expect(bracketPairCorrection('abc', 4, '('), isNull);
    });
  });
}
