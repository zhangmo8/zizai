/// 全书搜索：跨全部笔记本/章节的纯文本匹配，按章节分组返回。
///
/// 设计依据：docs/app/ui-sidebar.md §全书搜索。纯逻辑层；
/// UI 层负责入口、防抖与点击跳转（切换文档 + 编辑器定位）。
library;

import 'export.dart' show deltaToPlainText;
import 'find.dart';
import 'models.dart';

/// 单处匹配：定位信息 + 预览片段（[preview] 中
/// [previewMatchStart, previewMatchEnd) 为命中词，UI 高亮用）。
class BookSearchHit {
  const BookSearchHit({
    required this.documentId,
    required this.offset,
    required this.length,
    required this.preview,
    required this.previewMatchStart,
    required this.previewMatchEnd,
  });

  final String documentId;

  /// 在该章纯文本中的偏移（与编辑器 Quill 纯文本一致，可直接选中）。
  final int offset;
  final int length;

  final String preview;
  final int previewMatchStart;
  final int previewMatchEnd;
}

/// 一章的命中集合（分组展示）。
class BookSearchGroup {
  const BookSearchGroup({
    required this.notebookName,
    required this.documentId,
    required this.documentTitle,
    required this.totalMatches,
    required this.hits,
  });

  final String notebookName;
  final String documentId;
  final String documentTitle;

  /// 该章全部匹配数（可能大于 [hits] 长度——超出上限截断）。
  final int totalMatches;
  final List<BookSearchHit> hits;
}

/// 预览片段：匹配词前最多 20 字、后最多 40 字，不跨行，截断处加省略号。
BookSearchHit _hitFor(String documentId, String plain, FindMatch match) {
  var start = plain.lastIndexOf('\n', match.offset <= 0 ? 0 : match.offset - 1);
  start = start < 0 ? 0 : start + 1;
  var end = plain.indexOf('\n', match.end);
  if (end < 0) end = plain.length;
  final from = (match.offset - 20).clamp(start, match.offset);
  final to = (match.end + 40).clamp(match.end, end);
  final prefix = from > start ? '…' : '';
  final suffix = to < end ? '…' : '';
  final preview = '$prefix${plain.substring(from, to)}$suffix';
  final matchStart = prefix.length + (match.offset - from);
  return BookSearchHit(
    documentId: documentId,
    offset: match.offset,
    length: match.length,
    preview: preview,
    previewMatchStart: matchStart,
    previewMatchEnd: matchStart + match.length,
  );
}

/// 全书搜索。章节顺序沿用侧边栏；[query] 忽略首尾空白，空查询返回空。
/// 单章命中截断到 [maxHitsPerDocument]，全书截断到 [maxTotalHits]
/// （截断时组的 [BookSearchGroup.totalMatches] 仍是真实数）。
/// 每处理一章让出一次事件循环，长书不阻塞 UI 帧。
Future<List<BookSearchGroup>> searchBook({
  required List<Notebook> notebooks,
  required List<Document> Function(String notebookId) documentsOf,
  required String query,
  int maxHitsPerDocument = 20,
  int maxTotalHits = 200,
}) async {
  final needle = query.trim();
  if (needle.isEmpty) return const [];
  final groups = <BookSearchGroup>[];
  var total = 0;
  for (final notebook in notebooks) {
    for (final doc in documentsOf(notebook.id)) {
      if (total >= maxTotalHits) return groups;
      final String plain;
      try {
        plain = deltaToPlainText(doc.content);
      } on FormatException {
        continue; // 坏文档跳过，不阻塞全书搜索。
      }
      final matches = findMatches(plain, needle);
      if (matches.isEmpty) continue;
      final hits = <BookSearchHit>[];
      for (final match in matches.take(maxHitsPerDocument)) {
        if (total >= maxTotalHits) break;
        hits.add(_hitFor(doc.id, plain, match));
        total += 1;
      }
      if (hits.isEmpty) return groups;
      groups.add(
        BookSearchGroup(
          notebookName: notebook.name,
          documentId: doc.id,
          documentTitle: doc.title,
          totalMatches: matches.length,
          hits: hits,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
  }
  return groups;
}
