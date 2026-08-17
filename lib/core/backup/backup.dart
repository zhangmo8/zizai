/// 全量备份引擎：本地快照 → R2 上传备份；云端快照 → 下载恢复式导入。
///
/// 设计依据：docs/app/sync.md（备份模型）。
/// 凭据（backup.* 设置键）只在本机读取构造 store，绝不进入快照。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../db.dart';
import 's3_store.dart';
import 'snapshot.dart';

/// 备份状态机（状态栏/设置页消费）。
enum BackupState { idle, uploading, downloading, error }

class BackupManager extends ChangeNotifier {
  BackupManager({required this.db, required this.dbPath, S3Store? store})
      // ignore: prefer_initializing_formals —— 命名参数不能私有 this._ 初始化
      : _store = store;

  final Db db;

  /// 本地 db 文件路径（恢复前做文件级 .bak；空 = 内存库，跳过）。
  final String dbPath;

  S3Store? _store;

  /// 云端对象键（固定键 + R2 版本控制留历史）。
  static const backupKey = 'zizai-backup.json';

  final ValueNotifier<BackupState> state = ValueNotifier(BackupState.idle);
  final ValueNotifier<DateTime?> lastBackupAt = ValueNotifier(null);
  final ValueNotifier<String?> lastError = ValueNotifier(null);
  final ValueNotifier<int> failureCount = ValueNotifier(0);

  /// 凭据是否已配置（未配置时 UI 只显示配置项，隐藏操作按钮）。
  bool get configured => _store != null;

  /// 从设置表重建 store（配置变更后调用）。
  Future<void> reloadConfig() async {
    final accountId = await db.getSetting('backup.accountId') ?? '';
    final bucket = await db.getSetting('backup.bucket') ?? '';
    final accessKey = await db.getSetting('backup.accessKey') ?? '';
    final secretKey = await db.getSetting('backup.secretKey') ?? '';
    _store = (accountId.isNotEmpty &&
            bucket.isNotEmpty &&
            accessKey.isNotEmpty &&
            secretKey.isNotEmpty)
        ? S3Store(
            accountId: accountId,
            bucket: bucket,
            accessKey: accessKey,
            secretKey: secretKey,
          )
        : null;
    final last = await db.getSetting('backup.lastSuccessAt');
    final lastMs = int.tryParse(last ?? '');
    lastBackupAt.value = lastMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lastMs);
    notifyListeners();
  }

  /// 上传全量备份（手动触发）。返回是否成功。
  Future<bool> upload({String? deviceId, String? appVersion}) async {
    if (_store == null || _busy) return false;
    _set(BackupState.uploading);
    try {
      final snapshot = await buildSnapshot(
        db,
        deviceId: deviceId,
        appVersion: appVersion,
      );
      await _store!.putObject(backupKey, utf8.encode(jsonEncode(snapshot)));
      _onSuccess();
      return true;
    } catch (e) {
      _onFailure(e);
      return false;
    }
  }

  /// 下载并恢复：拉取最新快照 → 校验 → 本地 .bak → 全量导入。返回是否成功。
  Future<bool> download() async {
    if (_store == null || _busy) return false;
    _set(BackupState.downloading);
    try {
      final bytes = await _store!.getObject(backupKey);
      if (bytes == null) {
        throw const BackupException('云端还没有备份');
      }
      await importSnapshot(db, utf8.decode(bytes), dbPath: dbPath);
      _onSuccess();
      return true;
    } catch (e) {
      _onFailure(e);
      return false;
    }
  }

  bool get _busy =>
      state.value == BackupState.uploading ||
      state.value == BackupState.downloading;

  void _set(BackupState s) {
    state.value = s;
    notifyListeners();
  }

  void _onSuccess() {
    state.value = BackupState.idle;
    lastError.value = null;
    failureCount.value = 0;
    lastBackupAt.value = DateTime.now();
    // 持久化成功时间，重启后仍能判断备份是否新鲜。
    db.setSetting(
      'backup.lastSuccessAt',
      lastBackupAt.value!.millisecondsSinceEpoch.toString(),
      syncDirty: false,
    );
    notifyListeners();
  }

  void _onFailure(Object e) {
    state.value = BackupState.error;
    lastError.value = e.toString();
    failureCount.value++;
    notifyListeners();
  }
}
