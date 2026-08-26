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
    required this.updatedAt,
  });

  final String id;
  final String name;

  /// 同库内排序位（小在前）。
  final int position;
  final int createdAt;

  /// 本地变更时间（云同步 LWW 基准）。
  final int updatedAt;

  factory Notebook.fromRow(Map<String, Object?> row) => Notebook(
    id: row['id']! as String,
    name: row['name']! as String,
    position: row['position']! as int,
    createdAt: row['created_at']! as int,
    updatedAt: (row['updated_at'] as int?) ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is Notebook &&
      other.id == id &&
      other.name == name &&
      other.position == position &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, name, position, createdAt, updatedAt);
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
    this.status = DocumentStatus.draft,
    this.notes = '',
    this.volumeId,
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

  /// 章节状态标记（草稿/完成/待修改）。
  final DocumentStatus status;

  /// 章节备注（不进正文导出）：本章目的、出场人物、伏笔、待修改事项等。
  final String notes;

  /// 所属分卷（手动分卷模式写入；自动分卷为纯推导不写，null = 未归卷）。
  final String? volumeId;

  factory Document.fromRow(Map<String, Object?> row) => Document(
    id: row['id']! as String,
    notebookId: row['notebook_id']! as String,
    title: row['title']! as String,
    content: row['content']! as String,
    words: row['words']! as int,
    position: row['position']! as int,
    createdAt: row['created_at']! as int,
    updatedAt: row['updated_at']! as int,
    status: DocumentStatus.fromString(row['status'] as String? ?? 'draft'),
    notes: (row['notes'] as String?) ?? '',
    volumeId: row['volume_id'] as String?,
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
      other.updatedAt == updatedAt &&
      other.status == status &&
      other.notes == notes &&
      other.volumeId == volumeId;

  @override
  int get hashCode => Object.hash(
    id,
    notebookId,
    title,
    content,
    words,
    position,
    createdAt,
    updatedAt,
    status,
    notes,
    volumeId,
  );
}

/// 章节状态标记。
enum DocumentStatus {
  /// 草稿。
  draft,
  /// 完成。
  done,
  /// 待修改。
  todo;

  static DocumentStatus fromString(String s) {
    return switch (s) {
      'done' => DocumentStatus.done,
      'todo' => DocumentStatus.todo,
      _ => DocumentStatus.draft,
    };
  }

  String get label => switch (this) {
    DocumentStatus.draft => '草稿',
    DocumentStatus.done => '完成',
    DocumentStatus.todo => '待修改',
  };
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
    this.countPunctuation = false,
    this.focusDim = false,
  });

  /// 'system' | 'light' | 'dark'
  final String theme;

  /// 空串 = 系统默认字体。
  final String fontFamily;
  final double fontSize;
  final double lineHeight;

  /// 每日目标字数（100–50000）。
  final int dailyGoal;

  /// 是否将中文标点计入字数。
  final bool countPunctuation;

  /// 焦点暗淡：仅高亮光标所在段落，其余蒙页面底色（ui-editor.md §焦点暗淡）。
  final bool focusDim;

  static const settingsKeys = [
    'theme',
    'fontFamily',
    'fontSize',
    'lineHeight',
    'dailyGoal',
    'countPunctuation',
    'focusDim',
  ];

  Map<String, String> toMap() => {
    'theme': theme,
    'fontFamily': fontFamily,
    'fontSize': fontSize.toString(),
    'lineHeight': lineHeight.toString(),
    'dailyGoal': dailyGoal.toString(),
    'countPunctuation': countPunctuation.toString(),
    'focusDim': focusDim.toString(),
  };

  Settings copyWith({
    String? theme,
    String? fontFamily,
    double? fontSize,
    double? lineHeight,
    int? dailyGoal,
    bool? countPunctuation,
    bool? focusDim,
  }) => Settings(
    theme: theme ?? this.theme,
    fontFamily: fontFamily ?? this.fontFamily,
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    dailyGoal: dailyGoal ?? this.dailyGoal,
    countPunctuation: countPunctuation ?? this.countPunctuation,
    focusDim: focusDim ?? this.focusDim,
  );

  factory Settings.fromMap(Map<String, String> kv) {
    double parseD(String k, double fallback, double min, double max) {
      final v = double.tryParse(kv[k] ?? '');
      if (v == null) return fallback;
      return v.clamp(min, max);
    }

    int parseI(String k, int fallback, int min, int max) {
      final v = int.tryParse(kv[k] ?? '');
      if (v == null) return fallback;
      return v.clamp(min, max);
    }

    final theme = kv['theme'];
    return Settings(
      theme: (theme == 'system' || theme == 'light' || theme == 'dark')
          ? theme!
          : 'system',
      fontFamily: kv['fontFamily'] ?? '',
      fontSize: parseD('fontSize', 18, 12, 28),
      lineHeight: parseD('lineHeight', 1.8, 1.2, 2.4),
      dailyGoal: parseI('dailyGoal', 2000, 100, 50000),
      countPunctuation: kv['countPunctuation'] == 'true',
      focusDim: kv['focusDim'] == 'true',
    );
  }
}

/// 单个笔记本的每日写作目标。
class NotebookGoal {
  const NotebookGoal({this.enabled = true, this.words = 2000});

  final bool enabled;
  final int words;

  NotebookGoal copyWith({bool? enabled, int? words}) => NotebookGoal(
    enabled: enabled ?? this.enabled,
    words: (words ?? this.words).clamp(100, 50000),
  );
}

/// 分卷方式：自动（按每卷章数纯视觉推导） / 手动（用户建卷并归章，真数据）。
enum VolumeMode { auto, manual }

/// 单个笔记本的分卷配置（写作设置里的「分卷」）。
class VolumeCfg {
  const VolumeCfg({
    this.enabled = false,
    this.chapters = 20,
    this.mode = VolumeMode.auto,
  });

  final bool enabled;

  /// 每卷章数（1–500）。
  final int chapters;

  /// 分卷方式：自动分卷（每 N 章一卷，纯推导） / 手动分卷（用户建卷归章）。
  final VolumeMode mode;

  VolumeCfg copyWith({
    bool? enabled,
    int? chapters,
    VolumeMode? mode,
  }) => VolumeCfg(
    enabled: enabled ?? this.enabled,
    chapters: (chapters ?? this.chapters).clamp(1, 500),
    mode: mode ?? this.mode,
  );
}

/// 分卷（手动分卷模式的真数据分组）：属一个笔记本，按 position 排序。
class Volume {
  const Volume({
    required this.id,
    required this.notebookId,
    required this.name,
    required this.position,
    required this.createdAt,
  });

  final String id;
  final String notebookId;
  final String name;

  /// 卷在同书内的排序位（小在前）。
  final int position;
  final int createdAt;

  factory Volume.fromRow(Map<String, Object?> row) => Volume(
    id: row['id']! as String,
    notebookId: row['notebook_id']! as String,
    name: row['name']! as String,
    position: row['position']! as int,
    createdAt: row['created_at']! as int,
  );

  @override
  bool operator ==(Object other) =>
      other is Volume &&
      other.id == id &&
      other.notebookId == notebookId &&
      other.name == name &&
      other.position == position &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, notebookId, name, position, createdAt);
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
