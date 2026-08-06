/// 同步协议：envelope 序列化、push/pull 请求构造、版本协商。
///
/// 设计依据：docs/app/sync.md §3–§4（envelope 结构、协议 v1、
/// X-Sync-Protocol 与 schemaVersion 协商）。
library;

/// 云 blob 统一 envelope（sync.md §3）。
class SyncEnvelope {
  const SyncEnvelope({
    required this.t,
    required this.id,
    required this.data,
    required this.deleted,
    required this.updatedAt,
    required this.device,
    required this.schemaVersion,
  });

  /// 'doc' | 'notebook' | 'settings' | 'stats'
  final String t;
  final String id;
  final Map<String, dynamic> data;
  final bool deleted;
  final int updatedAt;
  final String device;
  final int schemaVersion;

  Map<String, dynamic> toJson() => {
        't': t,
        'id': id,
        'data': data,
        'deleted': deleted,
        'updatedAt': updatedAt,
        'device': device,
        'schemaVersion': schemaVersion,
      };

  static SyncEnvelope fromJson(Map<String, dynamic> json) => SyncEnvelope(
        t: json['t']! as String,
        id: json['id']! as String,
        data: (json['data'] as Map).cast<String, dynamic>(),
        deleted: json['deleted']! as bool,
        updatedAt: json['updatedAt']! as int,
        device: json['device']! as String,
        schemaVersion: json['schemaVersion']! as int,
      );
}

/// 协议版本（请求头 X-Sync-Protocol）与 blob 数据版本。
const int syncProtocolVersion = 1;
const int syncSchemaVersion = 1;

class PushResponse {
  const PushResponse({required this.serverTime, required this.applied});

  final int serverTime;
  final List<({String id, int updatedAt})> applied;

  static PushResponse fromJson(Map<String, dynamic> json) => PushResponse(
        serverTime: json['serverTime']! as int,
        applied: [
          for (final a in (json['applied'] as List))
            (
              id: (a as Map)['id']! as String,
              updatedAt: a['updatedAt']! as int,
            )
        ],
      );
}

class PullResponse {
  const PullResponse({required this.serverTime, required this.blobs});

  final int serverTime;
  final List<SyncEnvelope> blobs;

  static PullResponse fromJson(Map<String, dynamic> json) => PullResponse(
        serverTime: json['serverTime']! as int,
        blobs: [
          for (final b in (json['blobs'] as List))
            SyncEnvelope.fromJson((b as Map).cast<String, dynamic>())
        ],
      );
}

/// 协议/版本协商失败（409）→ 可读错误（客户端过旧，提示升级）。
class SyncProtocolException implements Exception {
  const SyncProtocolException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  @override
  String toString() => 'SyncProtocolException($status $code: $message)';
}

/// 其它同步失败（网络/HTTP 非 200）。
class SyncException implements Exception {
  const SyncException(this.message);

  final String message;

  @override
  String toString() => 'SyncException($message)';
}
