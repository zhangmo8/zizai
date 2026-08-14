import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/find.dart';

void main() {
  group('findMatches', () {
    test('全部匹配（不重叠、从左到右）', () {
      expect(findMatches('aaaa', 'aa'), const [
        FindMatch(offset: 0, length: 2),
        FindMatch(offset: 2, length: 2),
      ]);
    });

    test('默认大小写不敏感', () {
      expect(findMatches('Foo foo FOO', 'foo').length, 3);
      expect(
        findMatches('Foo foo', 'foo', caseSensitive: true),
        const [FindMatch(offset: 4, length: 3)],
      );
    });

    test('中文匹配与偏移', () {
      expect(findMatches('他说：他来了。他走了', '他'), const [
        FindMatch(offset: 0, length: 1),
        FindMatch(offset: 3, length: 1),
        FindMatch(offset: 7, length: 1),
      ]);
    });

    test('空查询/无匹配 → 空列表', () {
      expect(findMatches('abc', ''), isEmpty);
      expect(findMatches('abc', 'x'), isEmpty);
    });
  });

  group('nextMatchIndex', () {
    const matches = [
      FindMatch(offset: 2, length: 1),
      FindMatch(offset: 8, length: 1),
      FindMatch(offset: 20, length: 1),
    ];

    test('取光标之后最近的匹配', () {
      expect(nextMatchIndex(matches, 0), 0);
      expect(nextMatchIndex(matches, 3), 1);
      expect(nextMatchIndex(matches, 8), 1);
    });

    test('末尾之后回绕到 0；空列表 -1', () {
      expect(nextMatchIndex(matches, 99), 0);
      expect(nextMatchIndex(const [], 0), -1);
    });
  });
}
