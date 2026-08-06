/// 入口：App 装配。
///
/// 设计依据：docs/app/README.md §5/§6（main → 打开 db → 创建 controller →
/// 注入 Shell）、docs/app/update.md §2（db 打开/迁移失败 → 停止启动 + 明确错误）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';
import 'core/crash_journal.dart';
import 'core/db.dart';
import 'core/models.dart';
import 'state/library_controller.dart';
import 'state/settings_controller.dart';
import 'util/platform.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktopPlatform) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final Db db;
  final CrashJournal journal;
  try {
    final dir = await getApplicationSupportDirectory();
    db = await Db.open('${dir.path}${Platform.pathSeparator}zi-zai.db');
    journal = await CrashJournal.create(dir);
  } on LibraryException catch (e) {
    runApp(StartupErrorView(message: e.message, path: e.path));
    return;
  }
  final settings = SettingsController(db);
  final library = LibraryController(db);
  await settings.load();
  await library.restore();
  runApp(ZiZaiApp(library: library, settings: settings, journal: journal));
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
                  const Text('启动失败',
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  Text('$message${path == null ? '' : '\n库文件: $path'}'),
                  const SizedBox(height: 12),
                  Text(
                    '可尝试用同名 .bak 备份恢复数据库文件后重启。',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
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
