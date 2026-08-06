/// 设置状态与持久化（含主题/字体变更通知）。
///
/// 设计依据：docs/app/README.md §6（设置路径）、docs/app/ui-shell.md、
/// docs/app/style.md（主题三态）。
library;

import 'package:flutter/material.dart';

import '../core/db.dart';
import '../core/models.dart';

class SettingsController extends ChangeNotifier {
  SettingsController(this._db);

  final Db _db;

  Settings _settings = const Settings();
  Settings get settings => _settings;

  /// 主题三态：system / light / dark。
  ThemeMode get themeMode => switch (_settings.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  bool _loaded = false;
  bool get loaded => _loaded;

  /// 库文件路径（设置页「数据」区展示 / 打开目录）。
  String get dbPath => _db.path;

  /// 启动时从 settings 表载入。
  Future<void> load() async {
    _settings = await _db.loadSettings();
    _loaded = true;
    notifyListeners();
  }

  /// 修改设置：立即通知（主题/字体即时生效）并持久化。
  Future<void> update(Settings next) async {
    if (next == _settings) return;
    _settings = next;
    notifyListeners();
    await _db.saveSettings(next);
  }
}
