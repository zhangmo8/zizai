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

  /// 打字机滚动（光标行保持视口中部，settings 键 `typewriterScroll`，默认关）。
  bool _typewriterScroll = false;
  bool get typewriterScroll => _typewriterScroll;

  Future<void> setTypewriterScroll(bool enabled) async {
    if (_typewriterScroll == enabled) return;
    _typewriterScroll = enabled;
    notifyListeners();
    await _db.setSetting('typewriterScroll', enabled.toString());
  }

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
    _outlineOpen = values['outline.open'] == 'true';
    _notesOpen = values['notes.open'] == 'true';
    _typewriterScroll = values['typewriterScroll'] == 'true';
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
