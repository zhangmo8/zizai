/// 数据模型：Notebook / Document / Settings。
///
/// 设计依据：docs/app/README.md §4（数据模型）。
library;

/// 可恢复的库错误：上层（启动流程/UI）捕获后提示用户，不静默吞掉。
class LibraryException implements Exception {
  const LibraryException(this.message, {this.path});

  /// 面向用户的可读描述。
  final String message;

  /// 出问题的 db 文件路径（若有）。
  final String? path;

  @override
  String toString() =>
      'LibraryException($message${path == null ? '' : ', path: $path'})';
}

/// 笔记本（一个写作项目）。
class Notebook {
  const Notebook({
    required this.id,
    required this.name,
    required this.position,
    required this.createdAt,
  });

  final String id;
  final String name;

  /// 同库内排序位（小在前）。
  final int position;
  final int createdAt;

  factory Notebook.fromRow(Map<String, Object?> row) => Notebook(
        id: row['id']! as String,
        name: row['name']! as String,
        position: row['position']! as int,
        createdAt: row['created_at']! as int,
      );

  @override
  bool operator ==(Object other) =>
      other is Notebook &&
      other.id == id &&
      other.name == name &&
      other.position == position &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, name, position, createdAt);
}

/// 文档（一章/一篇），内容为富文本 Delta JSON。
class Document {
  const Document({
    required this.id,
    required this.notebookId,
    required this.title,
    required this.content,
    required this.words,
    required this.position,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String notebookId;
  final String title;

  /// Quill Delta JSON 字符串；空文档为 `'{}'`。
  final String content;

  /// 上次保存时纯文本字数快照（增量规则基准）。
  final int words;
  final int position;
  final int createdAt;
  final int updatedAt;

  factory Document.fromRow(Map<String, Object?> row) => Document(
        id: row['id']! as String,
        notebookId: row['notebook_id']! as String,
        title: row['title']! as String,
        content: row['content']! as String,
        words: row['words']! as int,
        position: row['position']! as int,
        createdAt: row['created_at']! as int,
        updatedAt: row['updated_at']! as int,
      );

  @override
  bool operator ==(Object other) =>
      other is Document &&
      other.id == id &&
      other.notebookId == notebookId &&
      other.title == title &&
      other.content == content &&
      other.words == words &&
      other.position == position &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode =>
      Object.hash(id, notebookId, title, content, words, position, createdAt, updatedAt);
}

/// 设置（UI 可配置项）。settings 表为 KV，其余键（如同步配置）由调用方
/// 直接经 `Db.getSetting/setSetting` 读写。
class Settings {
  const Settings({
    this.theme = 'system',
    this.fontFamily = '',
    this.fontSize = 18,
    this.lineHeight = 1.8,
    this.dailyGoal = 2000,
  });

  /// 'system' | 'light' | 'dark'
  final String theme;

  /// 空串 = 系统默认字体。
  final String fontFamily;
  final double fontSize;
  final double lineHeight;

  /// 每日目标字数（100–50000）。
  final int dailyGoal;

  static const settingsKeys = [
    'theme',
    'fontFamily',
    'fontSize',
    'lineHeight',
    'dailyGoal',
  ];

  Map<String, String> toMap() => {
        'theme': theme,
        'fontFamily': fontFamily,
        'fontSize': fontSize.toString(),
        'lineHeight': lineHeight.toString(),
        'dailyGoal': dailyGoal.toString(),
      };

  factory Settings.fromMap(Map<String, String> kv) {
    double parseD(String k, double fallback) =>
        double.tryParse(kv[k] ?? '') ?? fallback;
    int parseI(String k, int fallback) => int.tryParse(kv[k] ?? '') ?? fallback;
    return Settings(
      theme: kv['theme'] ?? 'system',
      fontFamily: kv['fontFamily'] ?? '',
      fontSize: parseD('fontSize', 18),
      lineHeight: parseD('lineHeight', 1.8),
      dailyGoal: parseI('dailyGoal', 2000),
    );
  }
}

/// last_open 表记录（启动恢复用）。
class LastOpen {
  const LastOpen({this.notebookId, this.documentId, required this.words});

  final String? notebookId;
  final String? documentId;
  final int words;

  factory LastOpen.fromRow(Map<String, Object?> row) => LastOpen(
        notebookId: row['notebook_id'] as String?,
        documentId: row['document_id'] as String?,
        words: row['words']! as int,
      );
}
