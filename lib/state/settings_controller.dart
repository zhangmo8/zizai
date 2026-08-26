/// 设置状态与持久化（含主题/字体变更通知）。
///
/// 设计依据：docs/app/README.md §6（设置路径）、docs/app/ui-shell.md、
/// docs/app/style.md（主题三态）。
library;

import 'package:flutter/material.dart';

import '../core/db.dart';
import '../core/models.dart';
import '../util/chinese.dart' show toChineseNumber;

class SettingsController extends ChangeNotifier {
  SettingsController(this._db);

  final Db _db;

  Settings _settings = const Settings();
  Settings get settings => _settings;

  Map<String, NotebookGoal> _notebookGoals = const {};

  NotebookGoal goalForNotebook(String? notebookId) {
    if (notebookId == null) return const NotebookGoal(enabled: false);
    return _notebookGoals[notebookId] ??
        NotebookGoal(words: _settings.dailyGoal);
  }

  /// 笔记本行首缩进开关（settings 键 `paragraphIndent.<notebookId>`，默认关）。
  Map<String, bool> _paragraphIndents = const {};

  /// 该笔记本是否开启「行首自动空两个字」（中文排版首行缩进）。
  bool indentForNotebook(String? notebookId) {
    if (notebookId == null) return false;
    return _paragraphIndents[notebookId] ?? false;
  }

  Future<void> setIndentForNotebook(
    String notebookId,
    bool enabled,
  ) async {
    if (_paragraphIndents[notebookId] == enabled) return;
    _paragraphIndents = {..._paragraphIndents, notebookId: enabled};
    notifyListeners();
    await _db.setSetting(
      'paragraphIndent.$notebookId',
      enabled.toString(),
    );
  }

  /// 笔记本分卷配置（settings 键 `volume.<notebookId>.enabled/.chapters/.mode`，
  /// 默认关闭、每卷 20 章、自动分卷）。
  Map<String, VolumeCfg> _volumes = const {};

  /// 自动分卷模式下「第 N 卷」的自定义名（settings 键
  /// `volume.<notebookId>.name.<n>`；空 = 恢复「第 N 卷」）。
  Map<String, Map<int, String>> _volumeAutoNames = const {};

  /// 该笔记本的分卷配置（未配置返回默认：关闭、自动分卷）。
  VolumeCfg volumeForNotebook(String? notebookId) {
    if (notebookId == null) return const VolumeCfg();
    return _volumes[notebookId] ?? const VolumeCfg();
  }

  /// 自动分卷模式第 [number] 卷的显示名；未重命名过返回「第 N 卷」。
  String autoVolumeName(String? notebookId, int number) {
    if (notebookId == null) return '第${toChineseNumber(number)}卷';
    final custom = _volumeAutoNames[notebookId]?[number]?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    return '第${toChineseNumber(number)}卷';
  }

  /// 设置自动分卷第 [number] 卷的自定义名；空串恢复「第 N 卷」。
  Future<void> setAutoVolumeName(
    String notebookId,
    int number,
    String name,
  ) async {
    final map = {..._volumeAutoNames[notebookId] ?? const <int, String>{}};
    if (name.trim().isEmpty) {
      map.remove(number);
    } else {
      map[number] = name.trim();
    }
    if (map.isEmpty) {
      _volumeAutoNames = {..._volumeAutoNames}..remove(notebookId);
    } else {
      _volumeAutoNames = {..._volumeAutoNames, notebookId: map};
    }
    notifyListeners();
    await _db.setSetting('volume.$notebookId.name.$number', name.trim());
  }

  Future<void> setVolumeForNotebook(
    String notebookId, {
    bool? enabled,
    int? chapters,
    VolumeMode? mode,
  }) async {
    final prev = volumeForNotebook(notebookId);
    final next = prev.copyWith(enabled: enabled, chapters: chapters, mode: mode);
    _volumes = {..._volumes, notebookId: next};
    notifyListeners();
    await _db.setSetting(
      'volume.$notebookId.enabled',
      next.enabled.toString(),
    );
    await _db.setSetting(
      'volume.$notebookId.chapters',
      next.chapters.toString(),
    );
    await _db.setSetting(
      'volume.$notebookId.mode',
      next.mode.name,
    );
    // 自动 → 手动：一次性按当前每卷分组建真实卷并归章（幂等，已有卷则跳过）。
    if (prev.mode == VolumeMode.auto &&
        next.mode == VolumeMode.manual &&
        next.enabled) {
      await _db.ensureAutoVolumes(
        notebookId,
        chapters: next.chapters,
        names: _volumeAutoNames[notebookId] ?? const {},
      );
    }
  }

  /// 侧边栏目录视图：分卷展示（grouped） / 平铺展示（flat）。
  /// settings 键 `sidebar.volumeView`，默认分卷展示。
  String _volumeView = 'grouped';
  String get volumeView => _volumeView;
  bool get volumeViewGrouped => _volumeView != 'flat';

  Future<void> setVolumeView(String view) async {
    if (_volumeView == view) return;
    _volumeView = view;
    notifyListeners();
    await _db.setSetting('sidebar.volumeView', view);
  }

  /// 笔记本管理页视图：grid / list（settings 键 `library.homeView`，默认 grid）。
  String _homeView = 'grid';
  String get homeView => _homeView;

  Future<void> setHomeView(String view) async {
    if (_homeView == view) return;
    _homeView = view;
    notifyListeners();
    await _db.setSetting('library.homeView', view);
  }

  /// 主题三态：system / light / dark。
  ThemeMode get themeMode => switch (_settings.theme) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  bool _loaded = false;
  bool get loaded => _loaded;

  /// 大纲面板展开状态（ui-editor.md §大纲面板：状态记忆）。
  bool _outlineOpen = false;
  bool get outlineOpen => _outlineOpen;

  Future<void> setOutlineOpen(bool open) async {
    if (_outlineOpen == open) return;
    _outlineOpen = open;
    notifyListeners();
    await _db.setSetting('outline.open', open.toString());
  }

  /// 章节备注面板展开状态（状态记忆）。
  bool _notesOpen = false;
  bool get notesOpen => _notesOpen;

  Future<void> setNotesOpen(bool open) async {
    if (_notesOpen == open) return;
    _notesOpen = open;
    notifyListeners();
    await _db.setSetting('notes.open', open.toString());
  }

  /// 库文件路径（设置页「数据」区展示 / 打开目录）。
  String get dbPath => _db.path;

  /// 底层库（设置页持久化备份等本地配置）。
  Db get db => _db;

  /// 启动时从 settings 表载入。
  Future<void> load() async {
    final values = await _db.allSettings();
    _settings = Settings.fromMap(values);
    _db.countPunctuation = _settings.countPunctuation;
    final goals = <String, NotebookGoal>{};
    for (final entry in values.entries) {
      const prefix = 'notebookGoal.';
      if (!entry.key.startsWith(prefix)) continue;
      final suffix = entry.key.substring(prefix.length);
      final split = suffix.lastIndexOf('.');
      if (split <= 0) continue;
      final notebookId = suffix.substring(0, split);
      final field = suffix.substring(split + 1);
      final current =
          goals[notebookId] ?? NotebookGoal(words: _settings.dailyGoal);
      if (field == 'enabled') {
        goals[notebookId] = current.copyWith(enabled: entry.value != 'false');
      } else if (field == 'words') {
        goals[notebookId] = current.copyWith(
          words: int.tryParse(entry.value) ?? _settings.dailyGoal,
        );
      }
    }
    _notebookGoals = goals;
    final indents = <String, bool>{};
    for (final entry in values.entries) {
      const prefix = 'paragraphIndent.';
      if (!entry.key.startsWith(prefix)) continue;
      final notebookId = entry.key.substring(prefix.length);
      if (notebookId.isEmpty) continue;
      indents[notebookId] = entry.value != 'false';
    }
    _paragraphIndents = indents;
    final volumes = <String, VolumeCfg>{};
    final volumeNames = <String, Map<int, String>>{};
    for (final entry in values.entries) {
      const prefix = 'volume.';
      if (!entry.key.startsWith(prefix)) continue;
      final suffix = entry.key.substring(prefix.length);
      // volume.<nb>.name.<n>：两级字段（自动分卷自定义卷名）。
      const nameToken = '.name.';
      final nameAt = suffix.indexOf(nameToken);
      if (nameAt >= 0) {
        final notebookId = suffix.substring(0, nameAt);
        final number =
            int.tryParse(suffix.substring(nameAt + nameToken.length));
        if (number != null && number > 0) {
          final map = {...volumeNames[notebookId] ?? const <int, String>{}};
          map[number] = entry.value;
          volumeNames[notebookId] = map;
        }
        continue;
      }
      final split = suffix.lastIndexOf('.');
      if (split <= 0) continue;
      final notebookId = suffix.substring(0, split);
      final field = suffix.substring(split + 1);
      final current =
          volumes[notebookId] ?? const VolumeCfg();
      if (field == 'enabled') {
        volumes[notebookId] = current.copyWith(enabled: entry.value != 'false');
      } else if (field == 'chapters') {
        volumes[notebookId] = current.copyWith(
          chapters: int.tryParse(entry.value) ?? 20,
        );
      } else if (field == 'mode') {
        volumes[notebookId] = current.copyWith(
          mode: entry.value == 'manual' ? VolumeMode.manual : VolumeMode.auto,
        );
      }
    }
    _volumes = volumes;
    _volumeAutoNames = volumeNames;
    _volumeView = values['sidebar.volumeView'] == 'flat' ? 'flat' : 'grouped';
    _homeView = values['library.homeView'] == 'list' ? 'list' : 'grid';
    _outlineOpen = values['outline.open'] == 'true';
    _notesOpen = values['notes.open'] == 'true';
    _loaded = true;
    notifyListeners();
  }

  /// 修改设置：立即通知（主题/字体即时生效）并持久化。
  Future<void> update(Settings next) async {
    if (next == _settings) return;
    _settings = next;
    _db.countPunctuation = next.countPunctuation;
    notifyListeners();
    await _db.saveSettings(next);
  }

  /// 笔记本目标独立保存；未配置的笔记本继承旧版全局目标值。
  Future<void> updateNotebookGoal(
    String notebookId, {
    bool? enabled,
    int? words,
  }) async {
    final next = goalForNotebook(
      notebookId,
    ).copyWith(enabled: enabled, words: words);
    _notebookGoals = {..._notebookGoals, notebookId: next};
    notifyListeners();
    await _db.setSetting(
      'notebookGoal.$notebookId.enabled',
      next.enabled.toString(),
    );
    await _db.setSetting(
      'notebookGoal.$notebookId.words',
      next.words.toString(),
    );
  }

  Future<void> resetNotebookGoals() async {
    _notebookGoals = const {};
    notifyListeners();
    await _db.deleteSettingsWithPrefix('notebookGoal.');
  }
}
