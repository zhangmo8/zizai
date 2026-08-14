/// 单文档大纲提取：Delta ops → 标题条目（文本 + 层级 + 偏移）。
///
/// 设计依据：docs/app/ui-editor.md §大纲面板。纯函数，编辑防抖管道调用。
library;

class OutlineEntry {
  const OutlineEntry({
    required this.text,
    required this.level,
    required this.offset,
  });

  /// 标题纯文本（去掉尾部换行；空标题保留空串）。
  final String text;

  /// 1–3，对应 header: 1|2|3。
  final int level;

  /// 标题行首在纯文本中的字符偏移（embed 记 1 字符，与 Quill 一致）。
  final int offset;

  @override
  bool operator ==(Object other) =>
      other is OutlineEntry &&
      other.text == text &&
      other.level == level &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(text, level, offset);

  @override
  String toString() => 'OutlineEntry(h$level "$text" @$offset)';
}

/// 从 Delta ops（`parseDeltaOps` 的输出格式）提取大纲。
///
/// Quill 的块级属性挂在行尾换行 op 上：一行的文本 op 在前，
/// 换行 op 的 `attributes.header` 决定该行是否为标题。
List<OutlineEntry> extractOutline(List<dynamic> ops) {
  final entries = <OutlineEntry>[];
  var offset = 0; // 当前扫描位置
  var lineStart = 0; // 当前行行首偏移
  final line = StringBuffer(); // 当前行已累计的文本

  void endLine(Map<String, dynamic>? attributes) {
    final header = attributes?['header'];
    if (header is int && header >= 1 && header <= 3) {
      entries.add(
        OutlineEntry(text: line.toString(), level: header, offset: lineStart),
      );
    }
    line.clear();
    lineStart = offset + 1; // 跳过换行符
  }

  for (final rawOp in ops) {
    if (rawOp is! Map) continue;
    final data = rawOp['insert'];
    final attributes = (rawOp['attributes'] as Map?)?.cast<String, dynamic>();
    if (data is String) {
      var rest = data;
      while (true) {
        final nl = rest.indexOf('\n');
        if (nl < 0) {
          line.write(rest);
          offset += rest.length;
          break;
        }
        line.write(rest.substring(0, nl));
        offset += nl;
        endLine(attributes);
        offset += 1;
        rest = rest.substring(nl + 1);
      }
    } else if (data != null) {
      // embed（图片等）按 1 字符计，与 toPlainText 的占位一致。
      line.write('￼');
      offset += 1;
    }
  }
  return entries;
}
