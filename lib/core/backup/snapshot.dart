/// 全量快照：本地各表 → 单个 JSON 对象；下载后恢复式导入。
///
/// 设计依据：docs/app/sync.md（备份模型：全量上传备份 / 下载解析恢复）。
/// 快照不携带任何 `sync.*` / `backup.*` 设备本地配置（凭据绝不离开本机）。
library;

import 'dart:convert';

import '../db.dart';
import '../models.dart' show ImportResult, documentToSnapshotJson;

/// 快照格式版本（独立于 DB schema；格式变更 +1，旧版可读则兼容读取）。
/// v1：notebooks/docs/settings/stats；
/// v2：+ volumes 数组、docs 补 status/notes/volumeId（v3/v4/v5 字段）。
const int snapshotFormatVersion = 2;

/// 快照内排除的本地配置前缀（设备私密/同步凭据不随备份走）。
const List<String> _excludedPrefixes = ['sync.', 'backup.'];

/// 备份相关可读错误（用户可见）。
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => 'BackupException($message)';
}

/// 全量导出：notebooks / docs / settings / stats → 快照 Map。
Future<Map<String, dynamic>> buildSnapshot(
  Db db, {
  String? deviceId,
  String? appVersion,
  int? nowMs,
}) async {
  final notebooks = await db.listNotebooks();
  final docs = await db.listAllDocuments();
  final volumes = await db.listAllVolumes();
  final allSettings = await db.allSettings();
  final settings = <String, String>{
    for (final e in allSettings.entries)
      if (!_isLocalKey(e.key)) e.key: e.value,
  };
  final stats = await db.allStats();
  return {
    'format': 'zizai-backup',
    'version': snapshotFormatVersion,
    'schemaVersion': await db.schemaVersion(),
    'createdAt': nowMs ?? DateTime.now().millisecondsSinceEpoch,
    'device': deviceId ?? '',
    'appVersion': appVersion ?? '',
    'data': {
      'notebooks': [
        for (final n in notebooks)
          {
            'id': n.id,
            'name': n.name,
            'position': n.position,
            'createdAt': n.createdAt,
            'updatedAt': n.updatedAt,
          }
      ],
      'docs': [for (final d in docs) documentToSnapshotJson(d)],
      'volumes': [
        for (final v in volumes)
          {
            'id': v.id,
            'notebookId': v.notebookId,
            'name': v.name,
            'position': v.position,
            'createdAt': v.createdAt,
          }
      ],
      'settings': settings,
      'stats': stats,
    },
  };
}

bool _isLocalKey(String key) =>
    _excludedPrefixes.any((p) => key.startsWith(p));

/// 解析并恢复快照：格式/schema 校验 → 备份本地 db 文件 → 全量替换导入。
///
/// [dbPath] 非空时先做 db 文件级备份（`.bak` 滚动保留），保证「永不丢字」。
Future<ImportResult> importSnapshot(
  Db db,
  String jsonText, {
  String dbPath = '',
}) async {
  final Map<String, dynamic> json;
  try {
    json = (jsonDecode(jsonText) as Map).cast<String, dynamic>();
  } on FormatException catch (e) {
    throw BackupException('快照不是有效 JSON: ${e.message}');
  } catch (_) {
    throw const BackupException('快照不是有效 JSON');
  }
  if (json['format'] != 'zizai-backup') {
    throw const BackupException('不是 zizai 备份文件');
  }
  final version = json['version'] as int? ?? 0;
  if (version > snapshotFormatVersion) {
    throw BackupException('快照格式过新（v$version），请升级 App 后恢复');
  }
  final remoteSchema = json['schemaVersion'] as int? ?? 0;
  final localSchema = await db.schemaVersion();
  if (remoteSchema > localSchema) {
    throw BackupException(
        '快照要求数据库 v$remoteSchema，当前 v$localSchema，请先升级 App');
  }
  final data = (json['data'] as Map).cast<String, dynamic>();
  final notebooks = ((data['notebooks'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final docs = ((data['docs'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  // v2：分卷数组；v1 快照无此键 → 空（兼容旧备份）。
  final volumes = ((data['volumes'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final settings =
      ((data['settings'] as Map?) ?? const {}).cast<String, String>();
  final stats = ((data['stats'] as Map?) ?? const {}).cast<String, int>();

  if (dbPath.isNotEmpty) {
    await backupDbFile(dbPath);
  }
  await db.importFull(
    notebooks: notebooks,
    volumes: volumes,
    docs: docs,
    settings: settings,
    stats: stats,
  );
  return ImportResult(
    notebooks: notebooks.length,
    volumes: volumes.length,
    docs: docs.length,
  );
}
