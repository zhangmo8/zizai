/// 崩溃日志：磁盘上的未保存缓冲（崩溃后重启可恢复）。
///
/// 设计依据：docs/app/ui-editor.md State Variants（崩溃恢复：启动时缓冲与
/// 库不一致 → 恢复确认条）。自动保存防抖 1s 期间崩溃，靠日志文件找回。
library;

import 'dart:convert';
import 'dart:io';

/// 日志内容（Delta JSON 载体）。
class CrashJournalEntry {
  const CrashJournalEntry({
    required this.documentId,
    required this.title,
    required this.content,
    required this.savedAt,
  });

  final String documentId;
  final String title;
  final String content;
  final int savedAt;

  Map<String, Object?> toJson() => {
        'documentId': documentId,
        'title': title,
        'content': content,
        'savedAt': savedAt,
      };

  static CrashJournalEntry fromJson(Map<String, Object?> json) =>
      CrashJournalEntry(
        documentId: json['documentId']! as String,
        title: json['title']! as String,
        content: json['content']! as String,
        savedAt: json['savedAt']! as int,
      );
}

/// 单文件崩溃日志：写临时文件再原子替换，避免半写状态。
class CrashJournal {
  CrashJournal(this._file);

  final File _file;

  /// 在应用支持目录创建日志实例（文件不存在则延迟创建）。
  static Future<CrashJournal> create(Directory dir) async {
    return CrashJournal(File('${dir.path}${Platform.pathSeparator}zi-zai.crash'));
  }

  String get path => _file.path;

  Future<void> write(CrashJournalEntry entry) async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(entry.toJson()));
    await tmp.rename(_file.path);
  }

  Future<CrashJournalEntry?> read() async {
    if (!await _file.exists()) return null;
    try {
      final data = jsonDecode(await _file.readAsString());
      if (data is Map) {
        return CrashJournalEntry.fromJson(data.cast<String, Object?>());
      }
    } on FormatException {
      // 损坏的日志直接丢弃，不阻塞启动。
    }
    return null;
  }

  Future<void> clear() async {
    if (await _file.exists()) {
      await _file.delete();
    }
  }
}
