/// 导出：Delta JSON → 纯文本。
///
/// 设计依据：docs/app/README.md §5（core/export）、docs/app/ui-editor.md。
library;

import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as quill;

import 'models.dart';

/// 空文档占位（schema 默认值）与空串。
const String emptyDeltaJson = '{}';

/// 将 Quill Delta JSON 转为纯文本；非法 JSON 或非 Delta 结构抛 [FormatException]。
///
/// `'{}'` 与 `''`（空文档占位）返回空串。
String deltaToPlainText(String deltaJson) {
  if (deltaJson.isEmpty || deltaJson == emptyDeltaJson) return '';
  final Object? data;
  try {
    data = jsonDecode(deltaJson);
  } on FormatException catch (e) {
    throw FormatException('非法 Delta JSON: ${e.message}', deltaJson);
  }
  if (data is! List) {
    throw FormatException('非法 Delta JSON: 期望数组', deltaJson);
  }
  if (data.isEmpty) return '';
  // Quill 文档要求末位 op 为 insert 且以换行结尾，缺则补 '\n'（规范化）。
  var ops = data.cast<Map<String, dynamic>>();
  for (final op in data) {
    if (op is! Map) {
      throw FormatException('非法 Delta JSON: op 必须是对象', deltaJson);
    }
    if (op['insert'] == null) {
      throw FormatException('非法 Delta JSON: op 缺少 insert', deltaJson);
    }
  }
  final last = ops.last;
  final lastInsert = last['insert'];
  if (lastInsert is String && !lastInsert.endsWith('\n')) {
    ops = [...ops, {'insert': '\n'}];
  }
  var text = quill.Document.fromJson(ops).toPlainText();
  // Quill 文档始终以换行结尾，toPlainText 会带出末尾 '\n'，剥掉它。
  if (text.endsWith('\n')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/// 文档 → 纯文本（导出 .txt / 分享用）。
String exportPlainText(Document document) => deltaToPlainText(document.content);
