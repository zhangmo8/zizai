import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/word_count.dart';

void main() {
  group('wordCount', () {
    test('中文按字符计', () {
      expect(wordCount('你好世界'), 4);
      expect(wordCount('天地玄黄宇宙洪荒'), 8);
    });

    test('日文/韩文按字符计', () {
      expect(wordCount('こんにちは'), 5);
      expect(wordCount('안녕하세요'), 5);
    });

    test('连续英文/数字按词计', () {
      expect(wordCount('Hello world'), 2);
      expect(wordCount('abc123 def'), 2);
      expect(wordCount('12345'), 1);
      expect(wordCount('A'), 1);
    });

    test('空白与标点不计', () {
      expect(wordCount('   '), 0);
      expect(wordCount('，。！？、；：'), 0);
      expect(wordCount('Hello, world!'), 2);
      expect(wordCount('——……'), 0);
    });

    test('中英混排', () {
      expect(wordCount('你好 Hello 世界123'), 6); // 你好(2) Hello(1) 世界123(2+1=3)
      expect(wordCount('abc, def。ghi'), 3);
      expect(wordCount('今天写了3000字'), 6); // 今 天 写 了(4) 3000(1) 字(1)
    });

    test('空串', () {
      expect(wordCount(''), 0);
    });
  });
}
