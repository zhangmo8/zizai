/// 单文档本地版本历史：轻量 JSON 文件存储，不依赖网络和数据库迁移。
///
/// 与云备份的「全量快照」（docs/app/sync.md）无关：这里的快照是单文档的
/// 历史版本留底，用于误删/大改后的本地回滚（docs/app/ui-editor.md §版本历史）。
library;

import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// 自动留底策略：保存链路在写库前按此判定是否先快照旧内容。
class SnapshotPolicy {
  const SnapshotPolicy({
    this.interval = const Duration(minutes: 10),
    this.minDropWords = 200,
    this.dropRatio = 0.2,
  });

  /// 距上次快照超过该间隔 → 周期留底。
  final Duration interval;

  /// 大删除判定：单次保存字数下降 ≥ [minDropWords]，
  /// 或（≥ 50 字且）降幅达到旧字数的 [dropRatio]。
  final int minDropWords;
  final double dropRatio;
}

class DocumentSnapshot {
  const DocumentSnapshot({
    required this.path,
    required this.documentId,
    required this.title,
    required this.content,
    required this.words,
    required this.createdAt,
  });

  final String path;
  final String documentId;
  final String title;
  final String content;
  final int words;
  final DateTime createdAt;

  factory DocumentSnapshot.fromJson(String path, Map<String, dynamic> json) {
    return DocumentSnapshot(
      path: path,
      documentId: json['documentId'] as String,
      title: json['title'] as String? ?? '未命名',
      content: json['content'] as String? ?? '{}',
      words: json['words'] as int? ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
    );
  }
}

class SnapshotHistory {
  SnapshotHistory({
    required this.rootPath,
    this.keep = 50,
    this.policy = const SnapshotPolicy(),
  });

  final String rootPath;

  /// 每文档保留的快照数上限，超出按时间淘汰最旧的。
  final int keep;
  final SnapshotPolicy policy;

  /// 各文档最近一次快照时间缓存（值为 null = 已扫描且确无快照）。
  final Map<String, DateTime?> _latestAt = {};

  Directory _dir(String documentId) => Directory('$rootPath/$documentId');

  Future<DocumentSnapshot> create(Document document, {DateTime? now}) async {
    final dir = _dir(document.id);
    await dir.create(recursive: true);
    final at = now ?? DateTime.now();
    // 同毫秒重复留底（如回滚前留底紧跟手动快照）时避让文件名，互不覆盖。
    var stamp = at.millisecondsSinceEpoch;
    File file;
    do {
      file = File('${dir.path}/$stamp.json');
      stamp += 1;
    } while (await file.exists());
    await file.writeAsString(
      jsonEncode({
        'documentId': document.id,
        'title': document.title,
        'content': document.content,
        'words': document.words,
        'createdAt': at.millisecondsSinceEpoch,
      }),
    );
    _latestAt[document.id] = at;
    await _prune(dir);
    return DocumentSnapshot(
      path: file.path,
      documentId: document.id,
      title: document.title,
      content: document.content,
      words: document.words,
      createdAt: at,
    );
  }

  /// 该文档全部快照，新的在前。
  Future<List<DocumentSnapshot>> list(String documentId) async {
    final dir = _dir(documentId);
    if (!await dir.exists()) return const [];
    final result = <DocumentSnapshot>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        result.add(
          DocumentSnapshot.fromJson(
            entity.path,
            (jsonDecode(await entity.readAsString()) as Map)
                .cast<String, dynamic>(),
          ),
        );
      } catch (_) {
        // 损坏的单个快照不应阻塞其它历史记录。
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<void> delete(DocumentSnapshot snapshot) async {
    await File(snapshot.path).delete();
    _latestAt.remove(snapshot.documentId);
  }

  /// 最近一次快照时间；本会话未扫描过时读一次目录。
  Future<DateTime?> latestAt(String documentId) async {
    if (_latestAt.containsKey(documentId)) return _latestAt[documentId];
    final snapshots = await list(documentId);
    final at = snapshots.isEmpty ? null : snapshots.first.createdAt;
    _latestAt[documentId] = at;
    return at;
  }

  /// 保存前自动留底判定，命中则快照 [previous]（库中当前=保存前内容）：
  /// - 该文档从无快照 → 建基线；
  /// - 本次保存字数骤降（删除较多）→ 留住删除前内容；
  /// - 距上次快照超过 [SnapshotPolicy.interval] → 周期留底。
  ///
  /// [nextWords] 为即将写入的新字数；空文档不留自动快照；返回 null = 未触发。
  Future<DocumentSnapshot?> maybeAutoSnapshot(
    Document previous, {
    required int nextWords,
    DateTime? now,
  }) async {
    if (previous.content.isEmpty || previous.content == '{}') return null;
    final at = now ?? DateTime.now();
    final last = await latestAt(previous.id);
    final drop = previous.words - nextWords;
    final bigDelete =
        drop >= policy.minDropWords ||
        (drop >= 50 && drop >= previous.words * policy.dropRatio);
    final baseline = last == null;
    final periodic = last != null && at.difference(last) >= policy.interval;
    if (!baseline && !bigDelete && !periodic) return null;
    return create(previous, now: at);
  }

  Future<void> _prune(Directory dir) async {
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) files.add(entity);
    }
    if (files.length <= keep) return;
    files.sort((a, b) => _stampOf(b).compareTo(_stampOf(a)));
    for (final file in files.skip(keep)) {
      await file.delete();
    }
  }

  static int _stampOf(File file) {
    final name = file.uri.pathSegments.last;
    return int.tryParse(name.substring(0, name.length - '.json'.length)) ?? 0;
  }
}
