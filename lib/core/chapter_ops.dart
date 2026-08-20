/// 章节操作：拆分、合并（纯函数层，操作 Delta JSON）。
///
/// 设计依据：用户需求「拆分章节/合并章节」。拆分在指定偏移处将文档一分为二；
/// 合并将源文档内容追加到目标文档末尾。均保留 Delta 格式属性。
library;

import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/quill_delta.dart' show Delta;

import 'export.dart' show parseDeltaOps;

/// 拆分结果：前半段 + 后半段 Delta JSON。
class SplitResult {
  const SplitResult({required this.firstContent, required this.secondContent});

  final String firstContent;
  final String secondContent;
}

/// 在纯文本偏移 [splitOffset] 处拆分文档内容。
///
/// [content] 为 Delta JSON；[splitOffset] 为纯文本中的字符偏移。
/// 前半段保留 offset 之前的内容，后半段保留 offset 之后的内容。
/// 两段均规范化为合法 Delta（末尾换行）。
SplitResult splitDocumentContent(String content, int splitOffset) {
  final ops = parseDeltaOps(content);
  if (ops.isEmpty) {
    return const SplitResult(firstContent: '{}', secondContent: '{}');
  }
  final doc = quill.Document.fromJson(ops);
  final plain = doc.toPlainText();
  final clamped = splitOffset.clamp(0, plain.length).toInt();

  final firstOps = _sliceOps(doc, 0, clamped);
  final secondOps = _sliceOps(doc, clamped, plain.length);

  return SplitResult(
    firstContent: _opsToJson(firstOps),
    secondContent: _opsToJson(secondOps),
  );
}

/// 从 Document 中提取 [start, end) 范围的 ops（保留格式属性）。
List<Map<String, dynamic>> _sliceOps(quill.Document doc, int start, int end) {
  if (start >= end) return const [];
  // 使用 compose：retain start，retain (end-start)，delete rest
  final sliceDelta = (Delta()
    ..retain(start)
    ..retain(end - start)
    ..delete(doc.length - end));
  final sliced = doc.toDelta().compose(sliceDelta);
  final result = <Map<String, dynamic>>[];
  for (final op in sliced.toList()) {
    final data = op.data;
    if (data is String && data.isNotEmpty) {
      result.add({
        'insert': data,
        if (op.attributes != null && op.attributes!.isNotEmpty)
          'attributes': Map<String, dynamic>.from(op.attributes!),
      });
    } else if (data is Map) {
      result.add({
        'insert': Map<String, dynamic>.from(data),
        if (op.attributes != null && op.attributes!.isNotEmpty)
          'attributes': Map<String, dynamic>.from(op.attributes!),
      });
    }
  }
  // 确保末尾换行
  if (result.isNotEmpty) {
    final lastInsert = result.last['insert'];
    if (lastInsert is String && !lastInsert.endsWith('\n')) {
      result.add({'insert': '\n'});
    }
  }
  return result;
}

String _opsToJson(List<Map<String, dynamic>> ops) {
  if (ops.isEmpty) return '{}';
  return jsonEncode(ops);
}

/// 合并两段 Delta JSON 内容：将 [second] 追加到 [first] 末尾。
///
/// 若 [first] 为空文档（`{}`），直接返回 [second]。
/// 合并时在两段之间保留段落分隔（确保 [first] 末尾有换行）。
String mergeDocumentContent(String first, String second) {
  final firstOps = parseDeltaOps(first);
  final secondOps = parseDeltaOps(second);
  if (firstOps.isEmpty) return second;
  if (secondOps.isEmpty) return first;

  // 确保第一段末尾有换行（段落分隔）
  final normalizedFirst = List<Map<String, dynamic>>.from(firstOps);
  final lastInsert = normalizedFirst.last['insert'];
  if (lastInsert is String && !lastInsert.endsWith('\n')) {
    normalizedFirst.add({'insert': '\n'});
  }

  final merged = [...normalizedFirst, ...secondOps];
  return _opsToJson(merged);
}
