/// 更新机制：清单拉取/版本比较/minDbSchema/sha256 校验/平台安装。
///
/// 设计依据：docs/app/update.md §1–§3（版本体系、R2 分发结构、update.json、
/// 检查与安装流程）、docs/app/README.md §8（平台差异）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;

import 'app_logger.dart';
import '../util/platform.dart'
    show isAndroidPlatform, isMacOS, isWindows;

/// 语义化版本比较：a < b → -1；a == b → 0；a > b → 1。
/// 支持 major.minor.patch[.build]；忽略非数字尾段。
int compareVersions(String a, String b) {
  final pa = _parts(a);
  final pb = _parts(b);
  for (var i = 0; i < 4; i++) {
    final va = i < pa.length ? pa[i] : 0;
    final vb = i < pb.length ? pb[i] : 0;
    if (va != vb) return va < vb ? -1 : 1;
  }
  return 0;
}

List<int> _parts(String v) {
  final m = RegExp(
    r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?',
  ).firstMatch(v.trim());
  if (m == null) return const [0];
  return [for (var i = 1; i <= 4; i++) int.tryParse(m.group(i) ?? '') ?? 0];
}

/// update.json 清单（docs/app/update.md §3）。
class UpdateManifest {
  const UpdateManifest({
    required this.latest,
    required this.minDbSchema,
    required this.platforms,
    this.notes,
    this.changelog = '',
  });

  final String latest;
  final int minDbSchema;
  final Map<String, ({String url, String sha256})> platforms;
  final String? notes;

  /// 本次更新说明（build.yml 从上一个 tag 到本 tag 的提交提取，markdown 列表）。
  final String changelog;

  static UpdateManifest fromJson(Map<String, dynamic> json) {
    final platforms = <String, ({String url, String sha256})>{};
    for (final e in ((json['platforms'] as Map?) ?? const {}).entries) {
      final p = (e.value as Map).cast<String, dynamic>();
      platforms[e.key] = (
        url: p['url']! as String,
        sha256: p['sha256']! as String,
      );
    }
    return UpdateManifest(
      latest: json['latest']! as String,
      minDbSchema: json['minDbSchema']! as int,
      platforms: platforms,
      notes: json['notes'] as String?,
      changelog: json['changelog'] as String? ?? '',
    );
  }
}

/// 更新检查结果。
enum UpdateStatus { none, available, downloading, ready, error }

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => 'UpdateException($message)';
}

class UpdateChecker {
  UpdateChecker({
    required this.httpClient,
    required this.updateUrl,
    required this.appVersion,
    required this.dbSchemaVersion,
    required this.installDir,
    this.logger,
  });

  final http.Client httpClient;
  final String updateUrl;
  final String appVersion;
  final int dbSchemaVersion;
  final AppLogger? logger;

  /// 安装包落盘目录（应用支持目录下 updates/）。
  final Directory installDir;

  final ValueNotifier<double?> progress = ValueNotifier(null);
  final ValueNotifier<UpdateStatus> status = ValueNotifier(UpdateStatus.none);
  final ValueNotifier<String?> error = ValueNotifier(null);
  final ValueNotifier<String?> readyPath = ValueNotifier(null);

  /// 发现的新版本号（available 态展示）。
  final ValueNotifier<String?> availableVersion = ValueNotifier(null);

  /// 最近一次拉到的待更新清单（UI 读取 changelog 展示更新说明用）。
  UpdateManifest? lastManifest;

  /// 有待处理的新版本（available / downloading / ready）→ 设置入口显示角标。
  bool get hasPendingUpdate =>
      status.value == UpdateStatus.available ||
      status.value == UpdateStatus.downloading ||
      status.value == UpdateStatus.ready;

  /// 拉取清单：有新版本（语义化 > 当前）且 minDbSchema <= 本地 → 可更新。
  Future<UpdateManifest?> fetchManifest() async {
    if (updateUrl.trim().isEmpty) {
      throw UpdateException('暂时无法检查更新');
    }
    await logger?.info(
      'update.manifest.request',
      data: {'url': updateUrl, 'currentVersion': appVersion},
    );
    final res = await httpClient
        .get(Uri.parse(updateUrl))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw UpdateException('清单拉取失败 (HTTP ${res.statusCode})');
    }
    final manifest = UpdateManifest.fromJson(
      (jsonDecode(res.body) as Map).cast<String, dynamic>(),
    );
    await logger?.info(
      'update.manifest.received',
      data: {
        'latest': manifest.latest,
        'currentVersion': appVersion,
        'minDbSchema': manifest.minDbSchema,
        'dbSchemaVersion': dbSchemaVersion,
      },
    );
    if (compareVersions(manifest.latest, appVersion) <= 0) return null;
    if (manifest.minDbSchema > dbSchemaVersion) {
      throw UpdateException(
        '新版要求数据库版本 ${manifest.minDbSchema}，当前 $dbSchemaVersion，请先升级中间版本',
      );
    }
    return manifest;
  }

  /// 下载并校验 sha256（不符拒绝安装并报错）。
  Future<File> download(String url, String sha256) async {
    await logger?.info('update.download.start', data: {'url': url});
    final res = await httpClient
        .get(Uri.parse(url))
        .timeout(const Duration(minutes: 5));
    if (res.statusCode != 200) {
      throw UpdateException('下载失败 (HTTP ${res.statusCode})');
    }
    final digest = crypto.sha256.convert(res.bodyBytes).toString();
    if (digest.toLowerCase() != sha256.toLowerCase()) {
      throw UpdateException('安装包校验失败（sha256 不符），已拒绝安装');
    }
    if (!await installDir.exists()) {
      await installDir.create(recursive: true);
    }
    final file = File(
      '${installDir.path}${Platform.pathSeparator}${_fileName(url)}',
    );
    await file.writeAsBytes(res.bodyBytes);
    await logger?.info(
      'update.download.complete',
      data: {
        'path': file.path,
        'bytes': res.bodyBytes.length,
        'sha256': digest,
      },
    );
    return file;
  }

  /// 检查更新（第一步）：拉取清单 → 有新版本则进入 available（待用户确认下载）。
  /// update.md §3：自用策略 = 提示式，不静默安装；发现新版须用户确认后才下载。
  Future<UpdateManifest?> check() async {
    error.value = null;
    try {
      final manifest = await fetchManifest();
      if (manifest == null) {
        status.value = UpdateStatus.none;
        return null;
      }
      lastManifest = manifest;
      status.value = UpdateStatus.available;
      availableVersion.value = manifest.latest;
      return manifest;
    } on UpdateException catch (e, stackTrace) {
      status.value = UpdateStatus.error;
      error.value = e.message;
      await logger?.error('update.check.failed', e, stackTrace);
      rethrow;
    } catch (e, stackTrace) {
      status.value = UpdateStatus.error;
      error.value = '检查更新失败: $e';
      await logger?.error('update.check.failed', e, stackTrace);
      rethrow;
    }
  }

  /// 下载安装（第二步）：仅 available 状态可触发；下载 → sha256 校验 → ready。
  Future<UpdateManifest> install() async {
    if (status.value != UpdateStatus.available) {
      throw UpdateException('当前没有待安装的更新');
    }
    error.value = null;
    status.value = UpdateStatus.downloading;
    try {
      final manifest = await fetchManifest(); // 重新拉取拿最新清单（含下载地址）
      final platform = _platformKey();
      final entry = manifest!.platforms[platform];
      if (entry == null) {
        throw UpdateException('当前平台无安装包（$platform）');
      }
      final file = await download(entry.url, entry.sha256);
      status.value = UpdateStatus.ready;
      readyPath.value = file.path;
      return manifest;
    } on UpdateException catch (e, stackTrace) {
      status.value = UpdateStatus.error;
      error.value = e.message;
      await logger?.error('update.install.failed', e, stackTrace);
      rethrow;
    } catch (e, stackTrace) {
      status.value = UpdateStatus.error;
      error.value = '下载安装失败: $e';
      await logger?.error('update.install.failed', e, stackTrace);
      rethrow;
    }
  }

  /// 兼容别名（历史测试/调用）：check + install。
  Future<UpdateManifest?> checkForUpdate() async {
    final manifest = await check();
    if (manifest != null) {
      await install();
    }
    return manifest;
  }

  static String _fileName(String url) {
    final seg = url.split('/').last;
    return seg.isEmpty ? 'update.bin' : seg;
  }

  static String _platformKey() {
    if (isAndroidPlatform) return 'android';
    if (isMacOS) return 'macos';
    if (isWindows) return 'windows';
    return 'macos';
  }
}
