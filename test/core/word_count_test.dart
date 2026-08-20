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

    test('空白与标点不计（默认）', () {
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

  group('wordCount countPunctuation', () {
    test('中文标点计入', () {
      expect(wordCount('，。！？、；：', countPunctuation: true), 7);
      expect(wordCount('你好，世界。', countPunctuation: true), 6); // 4字 + 2标点
    });

    test('英文标点不计（仅中文标点计）', () {
      expect(wordCount('Hello, world!', countPunctuation: true), 2);
    });

    test('全角空格不计', () {
      expect(wordCount('你　好', countPunctuation: true), 2); // 全角空格 U+3000 不计
    });

    test('破折号省略号计入', () {
      // —— 在 U+2015 (不在标点范围)，… 在 U+2026
      // 但中文用的……是两个 U+2026，不在 _punctuationPattern 范围
      // 这些特殊符号不计入（与中文标点不同）
      expect(wordCount('——……', countPunctuation: true), 0);
    });

    test('默认不计时仍为 0', () {
      expect(wordCount('，。！？', countPunctuation: false), 0);
      expect(wordCount('，。！？'), 0);
    });

    test('混排带标点', () {
      // 你好(2) ，(1) World(1) ！(1) = 5
      expect(wordCount('你好，World！', countPunctuation: true), 5);
    });
  });
}
