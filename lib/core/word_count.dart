/// 字数统计（纯函数）。
///
/// 规则（docs/app/ui-editor.md Word Count）：
/// - 中文/日文/韩文：1 字符 = 1 字；
/// - 连续英文/数字：按词计 1 字；
/// - 空白不计；
/// - 标点默认不计，[countPunctuation] 为 true 时中文标点计 1 字。
library;

/// CJK 字符 + CJK标点（标点仅在 countPunctuation 时匹配）。
final RegExp _cjkPattern = RegExp(
  r'[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\uAC00-\uD7AF]',
);

/// 中文标点（全角标点、CJK 符号），不含全角空格 U+3000。
final RegExp _punctuationPattern = RegExp(
  r'[\u3001-\u303F\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF65]',
);

/// 英文/数字连续串。
final RegExp _wordPattern = RegExp(r'[A-Za-z0-9]+');

/// 纯文本字数。空串返回 0。
///
/// [countPunctuation] 为 true 时，中文标点（。，！？等）也计 1 字。
int wordCount(String text, {bool countPunctuation = false}) {
  if (text.isEmpty) return 0;
  var count = 0;
  for (final _ in _cjkPattern.allMatches(text)) {
    count++;
  }
  if (countPunctuation) {
    for (final _ in _punctuationPattern.allMatches(text)) {
      count++;
    }
  }
  for (final _ in _wordPattern.allMatches(text)) {
    count++;
  }
  return count;
}
