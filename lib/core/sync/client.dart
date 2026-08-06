/// 同步引擎：journal 脏标记、push/pull、LWW 应用、tombstone、输家备份、退避重试。
///
/// 设计依据：docs/app/sync.md §5–§7（冲突与合并、触发与状态机、安全）、
/// docs/app/update.md §1（版本协商）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../db.dart';
import '../export.dart' show parseDeltaOps;
import '../models.dart';
import 'protocol.dart';

/// 同步状态机（状态栏与设置页消费）。
enum SyncState { idle, syncing, error }

/// 指数退避序列：30s / 1m / 5m / 上限 1h。
Duration retryDelayFor(int attempt) {
  const delays = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 5),
  ];
  if (attempt <= 0) return delays.first;
  if (attempt > delays.length) return const Duration(hours: 1);
  return delays[attempt - 1];
}

/// 客户端同步引擎。token 只进 Authorization 头，永不进 envelope/push 体。
class SyncClient extends ChangeNotifier {
  SyncClient({
    required this.db,
    required this.baseUrl,
    required this.backupDir,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
  })  : _http = httpClient ?? http.Client(),
        // ignore: prefer_initializing_formals —— 命名参数不能私有 this._ 初始化
        _timeout = timeout;

  final Db db;
  final String baseUrl;
  final Directory backupDir;
  final http.Client _http;
  final Duration _timeout;

  final ValueNotifier<SyncState> state = ValueNotifier(SyncState.idle);
  final ValueNotifier<DateTime?> lastSyncAt = ValueNotifier(null);
  final ValueNotifier<String?> lastError = ValueNotifier(null);
  final ValueNotifier<int> failureCount = ValueNotifier(0);

  /// 冲突输家备份计数（pull 应用时本地版本被云端覆盖并备份；状态栏/设置页提示）。
  final ValueNotifier<int> conflictBackups = ValueNotifier(0);

  String _deviceId = '';
  String? _token;
  bool _enabled = false;
  String? _baseUrlOverride;

  Timer? _pushDebounce;
  Timer? _retryTimer;
  int _retryAttempt = 0;
  bool _applying = false;
  bool _disposed = false;

  static const _pushDebounceDelay = Duration(seconds: 30);

  String get deviceId => _deviceId;
  bool get enabled => _enabled;

  /// 启动：deviceId（UUID 存本地）、读配置、挂接本地变更 → 调度推送。
  Future<void> initialize() async {
    _deviceId = await db.getSetting('sync.deviceId') ?? _generateDeviceId();
    await db.setSetting('sync.deviceId', _deviceId, syncDirty: false);
    await _readConfig();
    db.onMutation = () {
      if (_enabled && !_applying && !_disposed) schedulePush();
    };
    // 启动拉取（sync.md §6）。
    if (_enabled) {
      unawaited(pull());
    }
  }

  Future<void> _readConfig() async {
    _enabled = await db.getSetting('sync.enabled') == '1';
    _token = await db.getSetting('sync.token');
    _baseUrlOverride = await db.getSetting('sync.baseUrl');
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await db.setSetting('sync.enabled', value ? '1' : '0', syncDirty: false);
    if (value) {
      await syncNow();
    }
  }

  Future<void> setToken(String token) async {
    _token = token;
    await db.setSetting('sync.token', token, syncDirty: false);
  }

  /// 同步 Worker 地址（设置页配置；请求时生效）。
  Future<void> setBaseUrl(String url) async {
    _baseUrlOverride = url;
    await db.setSetting('sync.baseUrl', url, syncDirty: false);
  }

  String get effectiveBaseUrl => _baseUrlOverride ?? baseUrl;

  /// 保存防抖 30s 推送（同步不阻塞编辑）。
  void schedulePush() {
    _pushDebounce?.cancel();
    _pushDebounce = Timer(_pushDebounceDelay, () => unawaited(push()));
  }

  /// 手动「立即同步」：push + pull。
  Future<void> syncNow() async {
    await push();
    await pull();
  }

  @override
  void dispose() {
    _disposed = true;
    _pushDebounce?.cancel();
    _retryTimer?.cancel();
    if (db.onMutation != null) db.onMutation = null;
    super.dispose();
  }

  // ── push ──────────────────────────────────────────────────

  Future<void> push() async {
    if (!_enabled || _disposed) return;
    if (state.value == SyncState.syncing) return;
    _setSyncing();
    try {
      final blobs = await _buildPushBlobs();
      if (blobs.isEmpty) {
        _setIdle();
        return;
      }
      final resp = await _post('/sync/push', {
        'deviceId': _deviceId,
        'schemaVersion': syncSchemaVersion,
        'blobs': [for (final b in blobs) b.toJson()],
      });
      final result = PushResponse.fromJson(resp);
      for (final applied in result.applied) {
        await db.clearDirty(applied.id, serverTime: result.serverTime);
      }
      _onSuccess();
    } catch (e) {
      _onFailure(e);
    }
  }

  /// 构造待推送 envelope：脏实体 → 文档/笔记本/设置/统计。
  /// token 等 sync.* 键永不进 envelope。
  Future<List<SyncEnvelope>> _buildPushBlobs() async {
    final blobs = <SyncEnvelope>[];
    final ids = await db.dirtyEntityIds();
    for (final id in ids) {
      if (id == 'settings') {
        final all = await db.allSettings();
        final data = <String, String>{
          for (final e in all.entries)
            if (!e.key.startsWith('sync.')) e.key: e.value,
        };
        blobs.add(SyncEnvelope(
          t: 'settings',
          id: 'settings',
          data: data,
          deleted: false,
          updatedAt: 0, // 服务器签发
          device: _deviceId,
          schemaVersion: syncSchemaVersion,
        ));
        continue;
      }
      if (id == 'stats') {
        final stats = await db.allStats();
        blobs.add(SyncEnvelope(
          t: 'stats',
          id: 'stats',
          data: {'dates': stats},
          deleted: false,
          updatedAt: 0,
          device: _deviceId,
          schemaVersion: syncSchemaVersion,
        ));
        continue;
      }
      final doc = await db.getDocument(id);
      if (doc != null) {
        blobs.add(_docEnvelope(doc, deleted: false));
        continue;
      }
      final nb = await db.getNotebook(id);
      if (nb != null) {
        blobs.add(SyncEnvelope(
          t: 'notebook',
          id: nb.id,
          data: {'name': nb.name, 'position': nb.position},
          deleted: false,
          updatedAt: 0,
          device: _deviceId,
          schemaVersion: syncSchemaVersion,
        ));
        continue;
      }
      // 本地已删除 → tombstone（数据最小化，云端仅作传播标记）。
      if (id.startsWith('doc-')) {
        blobs.add(SyncEnvelope(
          t: 'doc',
          id: id,
          data: const {},
          deleted: true,
          updatedAt: 0,
          device: _deviceId,
          schemaVersion: syncSchemaVersion,
        ));
      } else if (id.startsWith('nb-')) {
        blobs.add(SyncEnvelope(
          t: 'notebook',
          id: id,
          data: const {},
          deleted: true,
          updatedAt: 0,
          device: _deviceId,
          schemaVersion: syncSchemaVersion,
        ));
      }
    }
    return blobs;
  }

  SyncEnvelope _docEnvelope(Document doc, {required bool deleted}) {
    List<dynamic> delta;
    try {
      delta = parseDeltaOps(doc.content);
    } on FormatException {
      delta = const [];
    }
    return SyncEnvelope(
      t: 'doc',
      id: doc.id,
      data: {
        'notebookId': doc.notebookId,
        'title': doc.title,
        'contentDelta': delta,
        'words': doc.words,
      },
      deleted: deleted,
      updatedAt: 0,
      device: _deviceId,
      schemaVersion: syncSchemaVersion,
    );
  }

  // ── pull ──────────────────────────────────────────────────

  Future<void> pull() async {
    if (!_enabled || _disposed) return;
    if (state.value == SyncState.syncing) return;
    _setSyncing();
    try {
      final since = int.tryParse(await db.getSetting('sync.lastPulledAt') ?? '') ?? 0;
      final resp = await _post('/sync/pull', {
        'deviceId': _deviceId,
        'since': since,
      });
      final result = PullResponse.fromJson(resp);
      _applying = true;
      try {
        // 笔记本先应用（文档引用其 notebookId）。
        for (final b in result.blobs.where((b) => b.t == 'notebook')) {
          await _applyNotebook(b);
        }
        for (final b in result.blobs.where((b) => b.t == 'doc')) {
          await _applyDoc(b);
        }
        for (final b in result.blobs.where((b) => b.t == 'settings')) {
          await _applySettings(b);
        }
        for (final b in result.blobs.where((b) => b.t == 'stats')) {
          await _applyStats(b);
        }
      } finally {
        _applying = false;
      }
      await db.setSetting('sync.lastPulledAt', result.serverTime.toString(),
          syncDirty: false);
      _onSuccess();
    } catch (e) {
      _onFailure(e);
    }
  }

  Future<void> _applyDoc(SyncEnvelope b) async {
    final local = await db.getDocument(b.id);
    if (local == null) {
      if (b.deleted) {
        await db.touchPulled(b.id, serverTime: b.updatedAt);
        return;
      }
      // 新建：notebook 不存在则建占位（拉取顺序先笔记本，此处兜底）。
      final nbId = b.data['notebookId'] as String? ?? '';
      if (await db.getNotebook(nbId) == null) {
        await db.applyCloudNotebook(
            id: nbId, name: '导入', position: 9999, updatedAt: b.updatedAt);
      }
      await db.applyCloudDocument(
        id: b.id,
        notebookId: nbId,
        title: b.data['title'] as String? ?? '',
        content: jsonEncode(b.data['contentDelta'] ?? const []),
        words: (b.data['words'] as num?)?.toInt() ?? 0,
        updatedAt: b.updatedAt,
      );
      await db.touchPulled(b.id, serverTime: b.updatedAt);
      return;
    }
    if (b.deleted) {
      if (b.updatedAt > local.updatedAt) {
        // 输家保护：本地有未推送修改 → 备份后删。
        if (await _isDirty(b.id)) {
          await _backupLocal(local);
        }
        await db.removeEntityNoDirty('documents', b.id);
        await db.touchPulled(b.id, serverTime: b.updatedAt);
      }
      return;
    }
    if (b.updatedAt > local.updatedAt) {
      // LWW：云端胜。本地脏且有本地更新 → 输家备份。
      if (await _isDirty(b.id)) {
        await _backupLocal(local);
      }
      await db.applyCloudDocument(
        id: b.id,
        notebookId: local.notebookId,
        title: b.data['title'] as String? ?? local.title,
        content: jsonEncode(b.data['contentDelta'] ?? const []),
        words: (b.data['words'] as num?)?.toInt() ?? local.words,
        updatedAt: b.updatedAt,
      );
      await db.touchPulled(b.id, serverTime: b.updatedAt);
    } else {
      await db.touchPulled(b.id, serverTime: b.updatedAt);
    }
  }

  Future<void> _applyNotebook(SyncEnvelope b) async {
    final local = await db.getNotebook(b.id);
    if (local == null) {
      if (b.deleted) return;
      await db.applyCloudNotebook(
        id: b.id,
        name: b.data['name'] as String? ?? '导入',
        position: (b.data['position'] as num?)?.toInt() ?? 0,
        updatedAt: b.updatedAt,
      );
      await db.touchPulled(b.id, serverTime: b.updatedAt);
      return;
    }
    if (b.deleted) {
      if (b.updatedAt > local.updatedAt) {
        await db.removeEntityNoDirty('notebooks', b.id);
        await db.touchPulled(b.id, serverTime: b.updatedAt);
      }
      return;
    }
    if (b.updatedAt > local.updatedAt) {
      await db.applyCloudNotebook(
        id: b.id,
        name: b.data['name'] as String? ?? local.name,
        position: (b.data['position'] as num?)?.toInt() ?? local.position,
        updatedAt: b.updatedAt,
      );
      await db.touchPulled(b.id, serverTime: b.updatedAt);
    } else {
      await db.touchPulled(b.id, serverTime: b.updatedAt);
    }
  }

  Future<void> _applySettings(SyncEnvelope b) async {
    if (b.deleted) return;
    for (final e in (b.data as Map).entries) {
      final key = e.key as String;
      if (key.startsWith('sync.')) continue; // 本地配置不覆盖
      await db.setSetting(key, e.value as String, syncDirty: false);
    }
    await db.touchPulled('settings', serverTime: b.updatedAt);
  }

  Future<void> _applyStats(SyncEnvelope b) async {
    if (b.deleted) return;
    final dates = (b.data['dates'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final e in dates.entries) {
      await db.upsertStat(e.key, (e.value as num).toInt());
    }
    await db.touchPulled('stats', serverTime: b.updatedAt);
  }

  Future<bool> _isDirty(String entityId) async {
    final dirtyIds = await db.dirtyEntityIds();
    return dirtyIds.contains(entityId);
  }

  /// 输家备份：.sync-bak/{docId}-{ts}.json，每文档保留最近 5 份（sync.md §5）。
  Future<void> _backupLocal(Document doc) async {
    final dir = Directory('${backupDir.path}${Platform.pathSeparator}sync-bak');
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}${doc.id}-'
        '${DateTime.now().millisecondsSinceEpoch}.json');
    await file.writeAsString(jsonEncode({
      'documentId': doc.id,
      'notebookId': doc.notebookId,
      'title': doc.title,
      'content': doc.content,
      'words': doc.words,
      'updatedAt': doc.updatedAt,
    }));
    conflictBackups.value++;
    notifyListeners();
    // 保留最近 5 份
    final existing = await dir
        .list()
        .where((f) => f.path.contains(doc.id))
        .toList();
    existing.sort((a, b) => a.path.compareTo(b.path));
    if (existing.length > 5) {
      for (final f in existing.take(existing.length - 5)) {
        await f.delete();
      }
    }
  }

  // ── HTTP 与状态 ───────────────────────────────────────────

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final token = _token ?? '';
    final res = await _http
        .post(
          Uri.parse('$baseUrl$path'),
          headers: {
            'content-type': 'application/json',
            'authorization': 'Bearer $token',
            'x-sync-protocol': '$syncProtocolVersion',
          },
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    if (res.statusCode == 409) {
      String code = 'protocol_mismatch';
      try {
        code = (jsonDecode(res.body) as Map)['error'] as String? ?? code;
      } catch (_) {}
      throw SyncProtocolException(
          res.statusCode, code, '同步协议/数据版本过旧，请升级 App');
    }
    if (res.statusCode != 200) {
      throw SyncException('同步失败 (HTTP ${res.statusCode})');
    }
    return (jsonDecode(res.body) as Map).cast<String, dynamic>();
  }

  void _setSyncing() {
    state.value = SyncState.syncing;
    notifyListeners();
  }

  void _setIdle() {
    _retryAttempt = 0;
    state.value = SyncState.idle;
    notifyListeners();
  }

  void _onSuccess() {
    _retryAttempt = 0;
    _retryTimer?.cancel();
    state.value = SyncState.idle;
    lastError.value = null;
    failureCount.value = 0;
    lastSyncAt.value = DateTime.now();
    notifyListeners();
  }

  void _onFailure(Object e) {
    state.value = SyncState.error;
    lastError.value = e.toString();
    failureCount.value++;
    _retryAttempt++;
    // 指数退避重试（30s / 1m / 5m / 上限 1h）。
    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelayFor(_retryAttempt), () {
      if (!_disposed) unawaited(syncNow());
    });
    notifyListeners();
  }

  static String _generateDeviceId() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
