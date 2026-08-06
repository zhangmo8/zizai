/// 字数统计（纯函数）。
///
/// 规则（docs/app/ui-editor.md Word Count）：
/// - 中文/日文/韩文：1 字符 = 1 字；
/// - 连续英文/数字：按词计 1 字；
/// - 空白与标点不计。
library;

final RegExp _wordPattern = RegExp(
  r'[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\uAC00-\uD7AF]'
  r'|[A-Za-z0-9]+',
);

/// 纯文本字数。空串返回 0。
int wordCount(String text) {
  if (text.isEmpty) return 0;
  var count = 0;
  for (final _ in _wordPattern.allMatches(text)) {
    count++;
  }
  return count;
}
