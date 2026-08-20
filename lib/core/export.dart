/// 导出：Delta JSON → 纯文本。
///
/// 设计依据：docs/app/README.md §5（core/export）、docs/app/ui-editor.md。
library;

import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart' as quill;

import 'models.dart';

/// 空文档占位（schema 默认值）与空串。
const String emptyDeltaJson = '{}';

/// 将 Quill Delta JSON 解析为规范化 ops；非法 JSON 或非 Delta 结构抛 [FormatException]。
///
/// Quill 文档要求末位 op 为 insert 且以换行结尾，缺则补 `\n`（规范化）。
/// `'{}'` 与 `''`（空文档占位）返回空列表。
List<Map<String, dynamic>> parseDeltaOps(String deltaJson) {
  if (deltaJson.isEmpty || deltaJson == emptyDeltaJson) return [];
  final Object? data;
  try {
    data = jsonDecode(deltaJson);
  } on FormatException catch (e) {
    throw FormatException('非法 Delta JSON: ${e.message}', deltaJson);
  }
  if (data is! List) {
    throw FormatException('非法 Delta JSON: 期望数组', deltaJson);
  }
  for (final op in data) {
    if (op is! Map) {
      throw FormatException('非法 Delta JSON: op 必须是对象', deltaJson);
    }
    if (op['insert'] == null) {
      throw FormatException('非法 Delta JSON: op 缺少 insert', deltaJson);
    }
  }
  var ops = data.cast<Map<String, dynamic>>();
  if (ops.isEmpty) return ops;
  final last = ops.last;
  final lastInsert = last['insert'];
  if (lastInsert is String && !lastInsert.endsWith('\n')) {
    ops = [...ops, {'insert': '\n'}];
  }
  return ops;
}

/// 将 Quill Delta JSON 转为纯文本；非法结构抛 [FormatException]。
///
/// `'{}'` 与 `''`（空文档占位）返回空串。
String deltaToPlainText(String deltaJson) {
  final ops = parseDeltaOps(deltaJson);
  if (ops.isEmpty) return '';
  var text = quill.Document.fromJson(ops).toPlainText();
  // Quill 文档始终以换行结尾，toPlainText 会带出末尾 '\n'，剥掉它。
  if (text.endsWith('\n')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/// 文档 → 纯文本（导出 .txt / 分享用）。
String exportPlainText(Document document) => deltaToPlainText(document.content);

/// 投稿格式纯文本：单章导出，标题 + 空行 + 段首缩进正文。
///
/// 适用于起点/番茄/晋江等网文平台投稿：标题独占一行（无前导空白）、
/// 标题后空一行、段首两个全角空格缩进、段间空行。
String exportSubmissionFormat(Document document) {
  final title = chapterHeading(document.title);
  final body = _formatBody(
    exportPlainText(document),
    const BookExportOptions(
      indentParagraphs: true,
      blankLineBetweenParagraphs: true,
    ),
  );
  final out = StringBuffer()..writeln(title)..writeln();
  if (body.isNotEmpty) out.writeln(body);
  final text = out.toString().trimRight();
  return text.isEmpty ? '$title\n' : '$text\n';
}

// ── 整书导出（docs/app/ui-settings.md §导出）─────────────────

/// 整书导出格式选项。
class BookExportOptions {
  const BookExportOptions({
    this.numberChapters = true,
    this.indentParagraphs = false,
    this.blankLineBetweenParagraphs = true,
  });

  /// 章节标题加「第 X 章」前缀（全书连续编号；标题已带编号则不重复加）。
  final bool numberChapters;

  /// 每段段首加两个全角空格（投稿纯文本惯例；Markdown 导出不适用）。
  final bool indentParagraphs;

  /// 段落之间空一行。
  final bool blankLineBetweenParagraphs;
}

/// 每章一文件导出的单个产物。
class BookExportFile {
  const BookExportFile({required this.fileName, required this.content});

  final String fileName;
  final String content;
}

/// 标题是否已带「第 X 章/回/节/卷」式编号。
final RegExp _numberedTitle = RegExp(
  r'^\s*第\s*[0-9０-９一二三四五六七八九十百千万零两]+\s*[章回节卷]',
);

/// 章节标题（去掉旧版遗留的 .md 扩展名）；[number] 为全书连续序号，
/// null 或标题已带编号时原样返回。
String chapterHeading(String title, {int? number}) {
  var text = title.trim();
  if (text.endsWith('.md')) {
    text = text.substring(0, text.length - 3).trimRight();
  }
  if (text.isEmpty) text = '未命名';
  if (number == null || _numberedTitle.hasMatch(text)) return text;
  return '第 $number 章 $text';
}

/// 纯文本规范化：统一换行、剥离零宽字符、折叠多余空行。
///
/// 导出前清理复制粘贴带入的脏字符与多余空行。
String cleanPlainText(String text) {
  var out = text;
  // 统一换行：\r\n / \r → \n
  out = out.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  // 剥离零宽字符（U+200B 零宽空格、U+FEFF BOM/零宽不换行空格）
  out = out.replaceAll('\u200B', '').replaceAll('\uFEFF', '');
  // 折叠 3 个及以上连续换行为单个空行（保留正常段间空行）
  out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return out;
}

/// 正文按段落重排：先规范化纯文本，再过滤空行、按选项加段首缩进/段间空行。
String _formatBody(String plain, BookExportOptions options) {
  final paragraphs = cleanPlainText(plain)
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.trim().isNotEmpty)
      .map(
        (line) => options.indentParagraphs && !line.startsWith('　')
            ? '　　${line.trimLeft()}'
            : line,
      )
      .toList();
  return paragraphs.join(options.blankLineBetweenParagraphs ? '\n\n' : '\n');
}

List<Document> _inNotebookOrder(List<Document> documents, String notebookId) =>
    [for (final doc in documents) if (doc.notebookId == notebookId) doc];

/// 整书 → 单个纯文本（投稿/归档）。章节顺序严格沿用侧边栏顺序；
/// 多笔记本（卷）时输出卷名分隔，单笔记本时直接从章节开始。
String exportBookPlainText(
  List<Notebook> notebooks,
  List<Document> documents, {
  BookExportOptions options = const BookExportOptions(),
}) {
  final out = StringBuffer();
  var chapter = 0;
  for (final notebook in notebooks) {
    if (notebooks.length > 1) {
      if (out.isNotEmpty) out.writeln();
      out.writeln(notebook.name.trim());
      out.writeln();
    }
    for (final doc in _inNotebookOrder(documents, notebook.id)) {
      chapter += 1;
      if (out.isNotEmpty) out.writeln();
      out.writeln(
        chapterHeading(doc.title, number: options.numberChapters ? chapter : null),
      );
      out.writeln();
      final body = _formatBody(exportPlainText(doc), options);
      if (body.isNotEmpty) out.writeln(body);
    }
  }
  final text = out.toString().trimRight();
  return text.isEmpty ? '' : '$text\n';
}

/// 整书 → 单个 Markdown（卷 = `#`，章 = `##`；单卷时章为 `#`）。
String exportBookMarkdown(
  List<Notebook> notebooks,
  List<Document> documents, {
  BookExportOptions options = const BookExportOptions(),
}) {
  final markdownOptions = BookExportOptions(
    numberChapters: options.numberChapters,
    // Markdown 段首缩进无意义（渲染器折叠行首空白），恒关。
    indentParagraphs: false,
    blankLineBetweenParagraphs: true,
  );
  final out = StringBuffer();
  final multiVolume = notebooks.length > 1;
  var chapter = 0;
  for (final notebook in notebooks) {
    if (multiVolume) {
      if (out.isNotEmpty) out.writeln();
      out.writeln('# ${notebook.name.trim()}');
      out.writeln();
    }
    for (final doc in _inNotebookOrder(documents, notebook.id)) {
      chapter += 1;
      if (out.isNotEmpty) out.writeln();
      final heading = chapterHeading(
        doc.title,
        number: options.numberChapters ? chapter : null,
      );
      out.writeln('${multiVolume ? '##' : '#'} $heading');
      out.writeln();
      final body = _formatBody(exportPlainText(doc), markdownOptions);
      if (body.isNotEmpty) out.writeln(body);
    }
  }
  final text = out.toString().trimRight();
  return text.isEmpty ? '' : '$text\n';
}

/// 整书 → 每章一个 Markdown 文件。文件名 `001 第 1 章 标题.md` 式，
/// 保证目录内按章节顺序排列；非法文件名字符替换为空格。
List<BookExportFile> exportBookMarkdownFiles(
  List<Notebook> notebooks,
  List<Document> documents, {
  BookExportOptions options = const BookExportOptions(),
}) {
  final files = <BookExportFile>[];
  var chapter = 0;
  for (final notebook in notebooks) {
    for (final doc in _inNotebookOrder(documents, notebook.id)) {
      chapter += 1;
      final heading = chapterHeading(
        doc.title,
        number: options.numberChapters ? chapter : null,
      );
      final out = StringBuffer()
        ..writeln('# $heading')
        ..writeln();
      final body = _formatBody(exportPlainText(doc), options);
      if (body.isNotEmpty) out.writeln(body);
      final order = chapter.toString().padLeft(3, '0');
      files.add(
        BookExportFile(
          fileName: '$order ${safeFileName(heading)}.md',
          content: '${out.toString().trimRight()}\n',
        ),
      );
    }
  }
  return files;
}

/// 文件名安全化：替换路径分隔与平台保留字符，压缩连续空白。
String safeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? '未命名' : cleaned;
}
