/// 全书搜索：跨全部笔记本/章节的纯文本匹配，按章节分组返回。
///
/// 设计依据：docs/app/ui-sidebar.md §全书搜索。纯逻辑层；
/// UI 层负责入口、防抖与点击跳转（切换文档 + 编辑器定位）。
library;

import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as quill;

import 'export.dart' show deltaToPlainText, parseDeltaOpsLenient;
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

/// 替换预览：单文档的全部匹配将如何替换。
class ReplacePreview {
  const ReplacePreview({
    required this.documentId,
    required this.documentTitle,
    required this.matchCount,
    required this.replacements,
  });

  final String documentId;
  final String documentTitle;
  final int matchCount;

  /// 每处替换的预览：原片段 → 替换后片段。
  final List<({String before, String after})> replacements;
}

/// 全书替换预览：按章节分组，展示每处匹配的替换前后对比。
///
/// 不修改数据——仅计算预览，供用户确认后再执行 [replaceAllInBook]。
Future<List<ReplacePreview>> previewReplaceInBook({
  required List<Notebook> notebooks,
  required List<Document> Function(String notebookId) documentsOf,
  required String query,
  required String replacement,
  int maxPreviewsPerDocument = 10,
}) async {
  final needle = query.trim();
  if (needle.isEmpty) return const [];
  final previews = <ReplacePreview>[];
  for (final notebook in notebooks) {
    for (final doc in documentsOf(notebook.id)) {
      final String plain;
      try {
        plain = deltaToPlainText(doc.content);
      } on FormatException {
        continue;
      }
      final matches = findMatches(plain, needle);
      if (matches.isEmpty) continue;
      final replacements = <({String before, String after})>[];
      for (final match in matches.take(maxPreviewsPerDocument)) {
        final from = (match.offset - 15).clamp(0, match.offset);
        final to = (match.end + 25).clamp(match.end, plain.length);
        final before = '${from > 0 ? '…' : ''}'
            '${plain.substring(from, to)}'
            '${to < plain.length ? '…' : ''}';
        final replaced = plain.substring(from, match.offset) +
            replacement +
            plain.substring(match.end, to);
        final after = '${from > 0 ? '…' : ''}'
            '$replaced'
            '${to < plain.length ? '…' : ''}';
        replacements.add((before: before, after: after));
      }
      previews.add(ReplacePreview(
        documentId: doc.id,
        documentTitle: doc.title,
        matchCount: matches.length,
        replacements: replacements,
      ));
      await Future<void>.delayed(Duration.zero);
    }
  }
  return previews;
}

/// 单文档替换结果。
class DocumentReplaceResult {
  const DocumentReplaceResult({
    required this.documentId,
    required this.replacedCount,
    required this.newContent,
  });

  final String documentId;
  final int replacedCount;
  final String newContent;
}

/// 在单文档 Delta 内容中替换全部匹配，返回新内容 JSON 与替换次数。
///
/// 使用 flutter_quill Document 操作 Delta，保留格式属性。
/// 非法 Delta 抛 FormatException；无匹配返回原内容。
DocumentReplaceResult replaceInDocument({
  required Document document,
  required String query,
  required String replacement,
}) {
  final needle = query.trim();
  if (needle.isEmpty) {
    return DocumentReplaceResult(
      documentId: document.id,
      replacedCount: 0,
      newContent: document.content,
    );
  }
  final ops = parseDeltaOpsLenient(document.content);
  if (ops.isEmpty) {
    return DocumentReplaceResult(
      documentId: document.id,
      replacedCount: 0,
      newContent: document.content,
    );
  }
  final qDoc = quill.Document.fromJson(ops);
  final plain = qDoc.toPlainText();
  final matches = findMatches(plain, needle);
  if (matches.isEmpty) {
    return DocumentReplaceResult(
      documentId: document.id,
      replacedCount: 0,
      newContent: document.content,
    );
  }
  // 从后往前替换，避免偏移变化。
  for (final match in matches.reversed) {
    qDoc.replace(match.offset, match.length, replacement);
  }
  final newContent = jsonEncode(qDoc.toDelta().toJson());
  return DocumentReplaceResult(
    documentId: document.id,
    replacedCount: matches.length,
    newContent: newContent,
  );
}

/// 全书替换：遍历全部文档，替换匹配并返回每文档结果。
///
/// [saveDocument] 由调用方提供（LibraryController.saveDocument），
/// 负责持久化与今日增量更新。返回总替换次数。
Future<int> replaceAllInBook({
  required List<Notebook> notebooks,
  required List<Document> Function(String notebookId) documentsOf,
  required String query,
  required String replacement,
  required Future<void> Function({
    required String documentId,
    required String title,
    required String content,
  }) saveDocument,
}) async {
  final needle = query.trim();
  if (needle.isEmpty) return 0;
  var total = 0;
  for (final notebook in notebooks) {
    for (final doc in documentsOf(notebook.id)) {
      try {
        final result = replaceInDocument(
          document: doc,
          query: needle,
          replacement: replacement,
        );
        if (result.replacedCount == 0) continue;
        await saveDocument(
          documentId: doc.id,
          title: doc.title,
          content: result.newContent,
        );
        total += result.replacedCount;
      } on FormatException {
        continue; // 坏文档跳过
      }
      await Future<void>.delayed(Duration.zero);
    }
  }
  return total;
}
