/// 单章节查找/替换：纯文本匹配（大小写不敏感可选）。
///
/// 设计依据：docs/app/ui-editor.md §查找与替换。纯函数，UI 层负责
/// 选区高亮与滚动定位；替换经 QuillController.replaceText 落到文档。
library;

class FindMatch {
  const FindMatch({required this.offset, required this.length});

  final int offset;
  final int length;

  int get end => offset + length;

  @override
  bool operator ==(Object other) =>
      other is FindMatch && other.offset == offset && other.length == length;

  @override
  int get hashCode => Object.hash(offset, length);

  @override
  String toString() => 'FindMatch(@$offset+$length)';
}

/// 在 [text] 中查找 [query] 的全部匹配（不重叠，从左到右）。
///
/// [caseSensitive] 为 false 时忽略大小写（Unicode 小写折叠）。
/// 空查询返回空列表。
List<FindMatch> findMatches(
  String text,
  String query, {
  bool caseSensitive = false,
}) {
  if (query.isEmpty) return const [];
  final haystack = caseSensitive ? text : text.toLowerCase();
  final needle = caseSensitive ? query : query.toLowerCase();
  final matches = <FindMatch>[];
  var from = 0;
  while (true) {
    final at = haystack.indexOf(needle, from);
    if (at < 0) break;
    matches.add(FindMatch(offset: at, length: needle.length));
    from = at + needle.length;
  }
  return matches;
}

/// [matches] 中当前应激活的下标：光标（或当前匹配）之后最近的一个。
///
/// [fromOffset] 之前的匹配被跳过；无匹配返回 -1；全部在其之前则回绕到 0。
int nextMatchIndex(List<FindMatch> matches, int fromOffset) {
  if (matches.isEmpty) return -1;
  for (var i = 0; i < matches.length; i++) {
    if (matches[i].offset >= fromOffset) return i;
  }
  return 0;
}
