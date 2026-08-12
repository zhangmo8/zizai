/// 入口：App 装配。
///
/// 设计依据：docs/app/README.md §5/§6（main → 打开 db → 创建 controller →
/// 注入 Shell）、docs/app/update.md §2（db 打开/迁移失败 → 停止启动 + 明确错误）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';
import 'core/backup/backup.dart';
import 'core/app_logger.dart';
import 'core/crash_journal.dart';
import 'core/db.dart';
import 'core/models.dart';
import 'core/update.dart';
import 'state/library_controller.dart';
import 'state/settings_controller.dart';
import 'util/platform.dart';

/// 构建时注入的默认更新地址（CI 传 --dart-define=UPDATE_URL=…）。
/// 为空 → 不自动检查；地址不在普通 UI 中展示。
const _defaultUpdateUrl = String.fromEnvironment(
  'UPDATE_URL',
  defaultValue: '',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktopPlatform) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final Db db;
  final CrashJournal journal;
  late final Directory dir;
  AppLogger? logger;
  try {
    dir = await getApplicationSupportDirectory();
    try {
      logger = await AppLogger.create(dir);
      _installGlobalErrorHandlers(logger);
      await logger.info('app.starting');
    } catch (_) {
      // 日志目录不可写时仍允许应用启动。
    }
    db = await Db.open('${dir.path}${Platform.pathSeparator}zi-zai.db');
    journal = await CrashJournal.create(dir);
  } on LibraryException catch (e, stackTrace) {
    await logger?.error(
      'app.startup.failed',
      e,
      stackTrace,
      data: {'path': e.path},
    );
    runApp(StartupErrorView(message: e.message, path: e.path));
    return;
  }
  final settings = SettingsController(db);
  final library = LibraryController(db);
  await settings.load();
  await library.restore();
  final backup = BackupManager(
    db: db,
    dbPath: '${dir.path}${Platform.pathSeparator}zi-zai.db',
  );
  await backup.reloadConfig();

  // 更新检查：App 版本来自 package_info；URL 由构建注入。
  var appVersion = '0.1.0';
  try {
    appVersion = (await PackageInfo.fromPlatform()).version;
  } catch (error, stackTrace) {
    await logger?.warning(
      'app.version.read.failed',
      message: error.toString(),
      data: {'stackTrace': stackTrace.toString()},
    );
  }
  final lastVersion = await db.getSetting('diagnostics.lastAppVersion');
  if (lastVersion == null) {
    await logger?.info('app.installed', data: {'version': appVersion});
  } else if (lastVersion != appVersion) {
    await logger?.info(
      'app.upgraded',
      data: {'from': lastVersion, 'to': appVersion},
    );
  }
  if (lastVersion != appVersion) {
    await db.setSetting(
      'diagnostics.lastAppVersion',
      appVersion,
      syncDirty: false,
    );
  }
  final dbSchema = await db.schemaVersion();
  final updatesDir = Directory('${dir.path}${Platform.pathSeparator}updates');
  await updatesDir.create(recursive: true);
  final legacyUpdateUrl = await db.getSetting('update.url');
  final updateChecker = UpdateChecker(
    httpClient: http.Client(),
    // 正式构建始终采用随版本注入的地址，避免旧版遗留设置长期覆盖新分发源。
    // 本地未注入地址时仍兼容开发环境中的旧设置。
    updateUrl: _defaultUpdateUrl.trim().isNotEmpty
        ? _defaultUpdateUrl
        : (legacyUpdateUrl ?? ''),
    appVersion: appVersion,
    dbSchemaVersion: dbSchema,
    installDir: updatesDir,
    logger: logger,
  );

  // 启动后异步检查一次（update.md §3）；地址为空（未配置且未注入）则跳过。
  if (updateChecker.updateUrl.trim().isNotEmpty) {
    unawaited(updateChecker.check().catchError((_) => null));
  }

  runApp(
    ZiZaiApp(
      library: library,
      settings: settings,
      journal: journal,
      logger: logger,
      backup: backup,
      updateChecker: updateChecker,
    ),
  );
}

void _installGlobalErrorHandlers(AppLogger logger) {
  final previousFlutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    unawaited(
      logger.error(
        'flutter.framework.error',
        details.exception,
        details.stack ?? StackTrace.current,
        message: details.context?.toDescription(),
      ),
    );
    if (previousFlutterHandler != null) {
      previousFlutterHandler(details);
    } else {
      FlutterError.presentError(details);
    }
  };

  final previousPlatformHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    unawaited(logger.error('dart.unhandled.error', error, stackTrace));
    return previousPlatformHandler?.call(error, stackTrace) ?? false;
  };
}

/// 启动失败（db 打不开/迁移失败）：停止启动 + 明确错误（update.md §2）。
class StartupErrorView extends StatelessWidget {
  const StartupErrorView({super.key, required this.message, this.path});

  final String message;
  final String? path;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '启动失败',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Text('$message${path == null ? '' : '\n库文件: $path'}'),
                  const SizedBox(height: 12),
                  Text(
                    '可尝试用同名 .bak 备份恢复数据库文件后重启。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
