/// 设置页：外观 / 写作 / 数据 三区（同步区归 sync-ui-003，关于区归 upd-001）。
///
/// 设计依据：docs/app/ui-settings.md（Region Layout / Interactions /
/// State Variants / Component Tree）、design.md（Notion token / 控件 /
/// 交互反馈）、docs/app/README.md §8（平台差异：桌面保存对话框 /
/// Android 系统分享）。
library;

import 'dart:io';

import 'package:archive/archive_io.dart' show extractFileToDisk;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:share_plus/share_plus.dart';

import '../app.dart' show appColorsOf;
import '../core/app_logger.dart';
import '../core/backup/backup.dart';
import '../core/export.dart' show exportPlainText;
import '../core/models.dart';
import '../core/update.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import '../util/platform.dart';
import 'export_dialog.dart';
import 'zz.dart';

/// 常见中文字体候选（「系统默认」= 空串）。跨端一致的字体枚举无官方 API，
/// 预设列表 + 编辑器回退系统字体兜底（style.md §4）。
const List<String> kFontChoices = [
  '',
  'PingFang SC',
  'Heiti SC',
  'Songti SC',
  'Kaiti SC',
  'Noto Sans CJK SC',
  'Microsoft YaHei',
  'SimSun',
];

/// 导出实现签名（桌面保存对话框 / Android 分享；测试可注入）。
typedef ExportHandler = Future<void> Function(Document doc, String plainText);

enum _SettingsCategory { appearance, writing, backup, data, about }

class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.settings,
    required this.library,
    this.backup,
    this.logger,
    this.updateChecker,
    this.dbSchemaVersion,
    this.exporter,
    this.autoFocusDailyGoal = false,
    this.autoFocusBackup = false,
  });

  final SettingsController settings;
  final LibraryController library;

  /// 备份引擎（null = 未接线，如单测；备份区隐藏）。
  final BackupManager? backup;

  /// 本地诊断日志（null = 未接线，如测试）。
  final AppLogger? logger;

  /// 更新检查（null = 未接线，如单测；关于区隐藏更新按钮）。
  final UpdateChecker? updateChecker;

  /// 本地 DB schema 版本（关于区展示）。
  final int? dbSchemaVersion;

  /// 导出实现（null = 默认：桌面 getSaveLocation 写 .txt / Android 分享）。
  final ExportHandler? exporter;

  /// 打开时聚焦「每日目标字数」（状态栏今日进度点击入口）。
  final bool autoFocusDailyGoal;

  /// 打开时定位「备份」区（状态栏备份指示点击入口）。
  final bool autoFocusBackup;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  bool _exporting = false;
  bool _checkingUpdate = false;
  final FocusNode _goalFocus = FocusNode();
  final TextEditingController _goalController = TextEditingController();
  String? _goalNotebookId;

  Settings get _s => widget.settings.settings;

  late _SettingsCategory _category = widget.autoFocusDailyGoal
      ? _SettingsCategory.writing
      : widget.autoFocusBackup && widget.backup != null
      ? _SettingsCategory.backup
      : _SettingsCategory.appearance;

  @override
  void initState() {
    super.initState();
    _goalNotebookId =
        widget.library.currentDocument?.notebookId ??
        widget.library.notebooks.firstOrNull?.id;
    _syncGoalController();
    if (widget.autoFocusDailyGoal && _goalNotebookId != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _goalFocus.requestFocus(),
      );
    }
    // 回填已保存的备份凭据（仅本地 settings 表；备份区未接线时跳过）。
    if (widget.backup != null) {
      final db = widget.settings.db;
      db.getSetting('backup.accountId').then((v) {
        if (mounted) _backupAccountController.text = v ?? '';
      });
      db.getSetting('backup.bucket').then((v) {
        if (mounted) _backupBucketController.text = v ?? '';
      });
      db.getSetting('backup.accessKey').then((v) {
        if (mounted) _backupAccessController.text = v ?? '';
      });
      db.getSetting('backup.secretKey').then((v) {
        if (mounted) _backupSecretController.text = v ?? '';
      });
    }
  }

  @override
  void dispose() {
    _goalFocus.dispose();
    _goalController.dispose();
    _backupAccountController.dispose();
    _backupBucketController.dispose();
    _backupAccessController.dispose();
    _backupSecretController.dispose();
    super.dispose();
  }

  void _update(Settings next) => widget.settings.update(next);

  Future<void> _export() async {
    final doc = widget.library.currentDocument;
    if (doc == null) return;
    final text = exportPlainText(doc);
    setState(() => _exporting = true);
    try {
      final handler = widget.exporter ?? _defaultExport;
      await handler(doc, text);
      if (mounted) showZzToast(context, '文档已导出');
    } catch (_) {
      if (mounted) showZzToast(context, '导出失败，请稍后重试', error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _defaultExport(Document doc, String text) async {
    if (isAndroidPlatform) {
      await SharePlus.instance.share(ShareParams(text: text));
    } else {
      final loc = await getSaveLocation(suggestedName: '${doc.title}.txt');
      if (loc == null) return; // 用户取消
      await File(loc.path).writeAsString(text);
    }
  }

  Future<void> _openDbDir() async {
    final dir = File(widget.settings.dbPath).parent.path;
    await _openDirectory(dir);
  }

  Future<void> _openLogDir() async {
    final logger = widget.logger;
    if (logger == null) return;
    try {
      await _openDirectory(logger.directory.path);
      if (mounted) showZzToast(context, '已打开日志目录');
    } catch (error, stackTrace) {
      await logger.error('diagnostics.open.failed', error, stackTrace);
      if (mounted) showZzToast(context, '无法打开日志目录：$error', error: true);
    }
  }

  Future<void> _shareLogs() async {
    final logger = widget.logger;
    if (logger == null) return;
    final files = await logger.files();
    if (files.isEmpty) {
      if (mounted) showZzToast(context, '暂无诊断日志');
      return;
    }
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [for (final file in files) XFile(file.path)],
          subject: '字在诊断日志',
        ),
      );
    } catch (error, stackTrace) {
      await logger.error('diagnostics.share.failed', error, stackTrace);
      if (mounted) showZzToast(context, '日志分享失败：$error', error: true);
    }
  }

  Future<void> _openDirectory(String dir) async {
    if (Platform.isMacOS) {
      const channel = MethodChannel('dev.zizai/open_path');
      await channel.invokeMethod('openPath', {'path': dir});
    } else if (Platform.isWindows) {
      final result = await Process.run('explorer', [dir]);
      if (result.exitCode != 0) throw StateError('文件管理器启动失败');
    } else if (Platform.isLinux) {
      final result = await Process.run('xdg-open', [dir]);
      if (result.exitCode != 0) throw StateError('文件管理器启动失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= 720;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(onClose: () => Navigator.of(context).maybePop()),
                if (!desktop)
                  _MobileSettingsNav(
                    selected: _category,
                    categories: _availableCategories,
                    onSelected: _selectCategory,
                  ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (desktop)
                        _SettingsNav(
                          selected: _category,
                          categories: _availableCategories,
                          onSelected: _selectCategory,
                          onReset: _confirmReset,
                        ),
                      Expanded(
                        child: _SettingsPage(
                          category: _category,
                          child: _buildCategoryPage(),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!desktop)
                  _MobileSettingsFooter(
                    onReset: _confirmReset,
                    onClose: () => Navigator.of(context).maybePop(),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<_SettingsCategory> get _availableCategories => [
    _SettingsCategory.appearance,
    _SettingsCategory.writing,
    if (widget.backup != null) _SettingsCategory.backup,
    _SettingsCategory.data,
    // 关于常驻：版本/更新组随 UpdateChecker 接线显隐，帮助组（快捷键）始终可用。
    _SettingsCategory.about,
  ];

  void _selectCategory(_SettingsCategory category) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _category = category);
  }

  Future<void> _confirmReset() async {
    final confirmed = await zzConfirm(
      context,
      title: '恢复默认设置？',
      message: '主题、字体、字号、行距和每日目标会恢复为默认值；不会删除文档或备份。',
      confirmLabel: '恢复默认',
      danger: true,
    );
    if (confirmed) {
      await widget.settings.update(const Settings());
      await widget.settings.resetNotebookGoals();
      _syncGoalController();
    }
  }

  Widget _buildCategoryPage() => switch (_category) {
    _SettingsCategory.appearance => _appearancePage(),
    _SettingsCategory.writing => _writingPage(),
    _SettingsCategory.backup => _backupPage(),
    _SettingsCategory.data => _dataPage(),
    _SettingsCategory.about => _aboutPage(),
  };

  Widget _appearancePage() => Column(
    children: [
      _SettingsGroup(
        label: '界面',
        children: [_row('主题', _themePicker()), _row('字体', _fontPicker())],
      ),
      _SettingsGroup(
        label: '编辑器',
        children: [
          _row(
            '字号',
            _slider(
              12,
              28,
              _s.fontSize,
              1,
              (v) => _update(_s.copyWith(fontSize: v)),
              '${_s.fontSize.round()}',
            ),
          ),
          _row(
            '行距',
            _slider(
              1.2,
              2.4,
              _s.lineHeight,
              0.1,
              (v) => _update(_s.copyWith(lineHeight: v)),
              _s.lineHeight.toStringAsFixed(1),
            ),
          ),
          _preview(),
        ],
      ),
    ],
  );

  Widget _writingPage() {
    final notebooks = widget.library.notebooks;
    final notebookId = _goalNotebookId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (notebooks.isEmpty || notebookId == null)
          _SettingsGroup(
            label: '写作目标',
            children: [
              Text(
                '新建笔记本后即可设定独立的每日目标',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          )
        else ...[
          () {
            final goal = widget.settings.goalForNotebook(notebookId);
            return _SettingsGroup(
              label: '写作目标',
              children: [
                _row(
                  '笔记本',
                  ZzSelect<String>(
                    value: notebookId,
                    display:
                        notebooks.firstWhere((n) => n.id == notebookId).name,
                    options: [
                      for (final n in notebooks) (label: n.name, value: n.id),
                    ],
                    onChanged: (id) {
                      setState(() {
                        _goalNotebookId = id;
                        _syncGoalController();
                      });
                    },
                  ),
                  description: '每本书独立计算今日进度',
                ),
                _row(
                  '启用今日目标',
                  ZzSwitch(
                    value: goal.enabled,
                    onChanged: (enabled) => widget.settings.updateNotebookGoal(
                      notebookId,
                      enabled: enabled,
                    ),
                  ),
                  description: '关闭后不在状态栏和沉浸模式显示',
                ),
                if (goal.enabled)
                  _row(
                    '每日目标字数',
                    _goalField(notebookId),
                    description: '只计入该笔记本今天新增的文字',
                  ),
              ],
            );
          }(),
        ],
        if (notebooks.isNotEmpty && notebookId != null)
          _SettingsGroup(
            label: '段落缩进',
            children: [
              _row(
                '行首自动缩进',
                ZzSwitch(
                  value: widget.settings.indentForNotebook(notebookId),
                  onChanged: (v) =>
                      widget.settings.setIndentForNotebook(notebookId, v),
                ),
                description: '针对「写作目标」选中的笔记本：新段落行首自动空两个全角空格',
              ),
            ],
          ),
        _SettingsGroup(
          label: '字数统计',
          children: [
            _row(
              '标点计入字数',
              ZzSwitch(
                value: _s.countPunctuation,
                onChanged: (v) =>
                    _update(_s.copyWith(countPunctuation: v)),
              ),
              description: '开启后中文标点（。，！？等）也计入字数',
            ),
          ],
        ),
        _SettingsGroup(
          label: '焦点暗淡',
          children: [
            _row(
              '暗淡非当前行',
              ZzSwitch(
                value: _s.focusDim,
                onChanged: (v) => _update(_s.copyWith(focusDim: v)),
              ),
              description: '仅高亮光标所在段落，其余变暗（编辑器顶栏可快速切换）；同时开启打字机滚动，光标行保持视口中部',
            ),
          ],
        ),
      ],
    );
  }

  Widget _backupPage() => _SettingsGroup(
    label: 'R2 备份',
    children: [
      _row(
        'Account ID',
        _backupAccountField(),
        description: 'Cloudflare R2 账户标识',
      ),
      _row('Bucket', _backupBucketField()),
      _row('Access Key', _backupAccessField()),
      _row('Secret Key', _backupSecretField()),
      _row('上次备份', _lastBackupRow()),
      Padding(padding: const EdgeInsets.only(top: 8), child: _backupActions()),
    ],
  );

  Widget _dataPage() => Column(
    children: [
      _SettingsGroup(
        label: '本地数据',
        children: [
          _row('数据库路径', _dbPathRow()),
          if (widget.logger != null)
            _row('诊断日志', _logPathRow(), description: '记录启动、升级、更新和未处理异常'),
        ],
      ),
      _SettingsGroup(
        label: '导出',
        children: [
          _row('当前文档', _exportRow(), description: '导出为纯文本文件'),
          _row(
            '整本书',
            _bookExportRow(),
            description: '合并 TXT / Markdown / 每章一个文件，可选章节编号与排版',
          ),
        ],
      ),
    ],
  );

  Widget _aboutPage() {
    final checker = widget.updateChecker;
    return Column(
      children: [
        if (checker != null) ...[
          _SettingsGroup(
            label: '版本信息',
            children: [
              _row(
                'App 版本',
                Text(checker.appVersion, style: const TextStyle(fontSize: 13)),
              ),
              _row(
                '数据库版本',
                Text(
                  'schema v${widget.dbSchemaVersion ?? 0}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
          _SettingsGroup(
            label: '软件更新',
            children: [_row('检查更新', _checkUpdateRow())],
          ),
        ],
        _SettingsGroup(
          label: '帮助',
          children: [
            _row(
              '快捷键说明',
              _shortcutsRow(),
              description: '全局快捷键、编辑与 Markdown 快捷语法',
            ),
          ],
        ),
      ],
    );
  }

  /// 「快捷键说明」按钮 → 弹快捷键面板（桌面 Dialog；Android 同为 Dialog）。
  Widget _shortcutsRow() {
    return ZzButton.secondary(
      label: '查看',
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => const _ShortcutsDialog(),
      ),
    );
  }

  Widget _row(String label, Widget control, {String? description}) =>
      _SettingsRow(label: label, description: description, control: control);

  Widget _themePicker() {
    return ZzSelect<String>(
      value: _s.theme,
      display: switch (_s.theme) {
        'system' => '跟随系统',
        'light' => '浅色',
        'dark' => '深色',
        _ => _s.theme,
      },
      options: const [
        (label: '跟随系统', value: 'system'),
        (label: '浅色', value: 'light'),
        (label: '深色', value: 'dark'),
      ],
      onChanged: (v) => _update(_s.copyWith(theme: v)),
    );
  }

  Widget _fontPicker() {
    return ZzSelect<String>(
      value: _s.fontFamily,
      display: _s.fontFamily.isEmpty ? '系统默认' : _s.fontFamily,
      options: [
        for (final f in kFontChoices) (label: f.isEmpty ? '系统默认' : f, value: f),
      ],
      onChanged: (v) => _update(_s.copyWith(fontFamily: v)),
    );
  }

  Widget _slider(
    double min,
    double max,
    double value,
    double step,
    ValueChanged<double> onChanged,
    String label,
  ) {
    return Row(
      children: [
        Expanded(
          child: ZzSlider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(
            label,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    );
  }

  /// 示例文本预览：字号/行距/字体实时作用于编辑器同款样式。
  Widget _preview() {
    final s = _s;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: appColorsOf(context).callout,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '预览：字在 天地玄黄 AaBb 123',
        style: TextStyle(
          fontSize: s.fontSize,
          height: s.lineHeight,
          fontFamily: s.fontFamily.isEmpty ? null : s.fontFamily,
        ),
      ),
    );
  }

  void _syncGoalController() {
    final current = widget.settings.goalForNotebook(_goalNotebookId).words;
    _goalController.text = current.toString();
  }

  Widget _goalField(String notebookId) {
    final current = widget.settings
        .goalForNotebook(notebookId)
        .words
        .toString();
    if (!_goalFocus.hasFocus && _goalController.text != current) {
      _goalController.text = current;
    }
    return _notionField(
      controller: _goalController,
      hint: '100–50000',
      keyboardType: TextInputType.number,
      focusNode: _goalFocus,
      onSubmitted: (v) {
        final n = int.tryParse(v.trim());
        if (n == null || n < 100 || n > 50000) return;
        widget.settings.updateNotebookGoal(notebookId, words: n);
      },
    );
  }

  // ── 备份区（全量上传备份 / 下载恢复）──────────────────────

  late final TextEditingController _backupAccountController =
      TextEditingController();
  late final TextEditingController _backupBucketController =
      TextEditingController();
  late final TextEditingController _backupAccessController =
      TextEditingController();
  late final TextEditingController _backupSecretController =
      TextEditingController();

  Future<void> _saveBackupConfig(String key, String value) async {
    await widget.settings.db.setSetting(key, value.trim());
    await widget.backup!.reloadConfig();
  }

  /// Notion 式输入框（浅底、focus accent 描边；见 zz.dart）。
  Widget _notionField({
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    TextInputType? keyboardType,
    FocusNode? focusNode,
    required ValueChanged<String> onSubmitted,
  }) {
    return ZzTextField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: keyboardType,
      obscure: obscure,
      hint: hint,
      onSubmitted: onSubmitted,
    );
  }

  Widget _backupAccountField() {
    return _notionField(
      controller: _backupAccountController,
      hint: 'R2 Account ID（10 位十六进制）',
      onSubmitted: (v) => _saveBackupConfig('backup.accountId', v),
    );
  }

  Widget _backupBucketField() {
    return _notionField(
      controller: _backupBucketController,
      hint: 'R2 Bucket 名',
      onSubmitted: (v) => _saveBackupConfig('backup.bucket', v),
    );
  }

  Widget _backupAccessField() {
    return _notionField(
      controller: _backupAccessController,
      hint: 'R2 Access Key ID',
      onSubmitted: (v) => _saveBackupConfig('backup.accessKey', v),
    );
  }

  Widget _backupSecretField() {
    return _notionField(
      controller: _backupSecretController,
      hint: 'R2 Secret Access Key',
      obscure: true, // 掩码显示；凭据仅存本地 settings 表，绝不进快照
      onSubmitted: (v) => _saveBackupConfig('backup.secretKey', v),
    );
  }

  Widget _lastBackupRow() {
    final backup = widget.backup!;
    return ListenableBuilder(
      listenable: backup.lastBackupAt,
      builder: (context, _) {
        final at = backup.lastBackupAt.value;
        return Text(
          at == null ? '从未备份' : '${_relativeTime(at)}（${at.toLocal()}）',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      },
    );
  }

  static String _relativeTime(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    return '${diff.inDays} 天前';
  }

  Widget _backupActions() {
    final backup = widget.backup!;
    return ListenableBuilder(
      listenable: Listenable.merge([
        backup.state,
        backup.failureCount,
        backup.lastError,
      ]),
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final busy =
            backup.state.value == BackupState.uploading ||
            backup.state.value == BackupState.downloading;
        final error = backup.lastError.value;
        final configured = backup.configured;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ZzButton.primary(
                  label: '上传备份',
                  busy: backup.state.value == BackupState.uploading,
                  onPressed: (!configured || busy) ? null : _runUpload,
                ),
                const SizedBox(width: 8),
                ZzButton.secondary(
                  label: '下载恢复',
                  color: colors.error,
                  busy: backup.state.value == BackupState.downloading,
                  onPressed: (!configured || busy) ? null : _confirmDownload,
                ),
                if (error != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      error,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.error),
                    ),
                  ),
                ],
              ],
            ),
            if (!configured)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '填写四项 R2 凭据后即可备份（Secret 仅存本机）',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            if (error != null && !busy)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: ZzButton.link(
                  label: '重试',
                  color: colors.error,
                  onPressed: () => backup.upload(),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _runUpload() async {
    final ok = await widget.backup!.upload();
    if (!mounted) return;
    showZzToast(context, ok ? '备份已上传' : '备份失败，请稍后重试', error: !ok);
  }

  /// 下载恢复会覆盖本地数据 → 二次确认；恢复后刷新库与设置控制器。
  Future<void> _confirmDownload() async {
    final confirmed = await zzConfirm(
      context,
      title: '下载恢复',
      message:
          '将用云端备份覆盖本地全部数据。\n'
          '本地数据会先自动备份为 .bak 文件（保留最近 3 份），仍可找回。',
      confirmLabel: '恢复',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    final ok = await widget.backup!.download();
    if (ok && mounted) {
      await widget.library.restore();
      await widget.settings.load();
      if (mounted) {
        showZzToast(context, '已从云端备份恢复');
      }
    } else if (mounted) {
      showZzToast(context, '恢复失败，请稍后重试', error: true);
    }
  }

  /// 检查更新：平时次级按钮；发现新版转 accent 主按钮（徽标语义）；
  /// 下载中按钮 spinner + 旁侧 4px 细进度条（design.md §5.2/§5.4）。
  Widget _checkUpdateRow() {
    final checker = widget.updateChecker!;
    return ListenableBuilder(
      listenable: Listenable.merge([
        checker.status,
        checker.error,
        checker.progress,
      ]),
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final status = checker.status.value;
        final downloading = status == UpdateStatus.downloading;
        final version = checker.availableVersion.value ?? '';
        final label = switch (status) {
          UpdateStatus.available => '下载并安装 v$version',
          UpdateStatus.ready => '安装 v$version',
          _ => '检查更新',
        };
        // 有待处理的新版本时按钮升为主按钮（accent 高亮），平时保持次级。
        final highlight = status == UpdateStatus.available ||
            status == UpdateStatus.ready ||
            downloading;
        final busy = downloading || _checkingUpdate;
        final button = highlight
            ? ZzButton.primary(
                label: label,
                busy: busy,
                onPressed: busy ? null : _runUpdateCheck,
              )
            : ZzButton.secondary(
                label: label,
                busy: busy,
                onPressed: busy ? null : _runUpdateCheck,
              );
        return Row(
          children: [
            button,
            if (downloading) ...[
              const SizedBox(width: 12),
              SizedBox(
                width: 120,
                child: LinearProgressIndicator(
                  value: checker.progress.value,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                  color: colors.primary,
                  backgroundColor: colors.onSurface.withValues(alpha: 0.12),
                ),
              ),
              if (checker.progress.value != null) ...[
                const SizedBox(width: 8),
                Text(
                  '${(checker.progress.value! * 100).round()}%',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ],
        );
      },
    );
  }

  Future<void> _runUpdateCheck() async {
    final checker = widget.updateChecker!;
    final status = checker.status.value;
    if (status == UpdateStatus.none || status == UpdateStatus.error) {
      setState(() => _checkingUpdate = true);
    }
    try {
      switch (status) {
        case UpdateStatus.none || UpdateStatus.error:
          final manifest = await checker.check();
          if (!mounted) return;
          showZzToast(
            context,
            manifest == null ? '已是最新版本' : '发现新版本 v${manifest.latest}',
          );
        case UpdateStatus.available:
          final manifest = await checker.install();
          if (mounted) showZzToast(context, 'v${manifest.latest} 已下载并通过校验');
        case UpdateStatus.ready:
          await _installPackage();
          if (mounted) {
            showZzToast(
              context,
              isAndroidPlatform ? '已打开系统安装器' : '已打开更新文件夹，替换应用后重启',
            );
          }
        case UpdateStatus.downloading:
          break;
      }
    } catch (e, stackTrace) {
      await widget.logger?.error('update.action.failed', e, stackTrace);
      if (mounted) {
        final checkerMessage = checker.error.value;
        final message = e is UpdateException
            ? e.message
            : checkerMessage ?? '更新失败，请稍后重试';
        showZzToast(context, message, error: true);
      }
    } finally {
      if (mounted && _checkingUpdate) setState(() => _checkingUpdate = false);
    }
  }

  /// 平台安装：
  /// - Android：经 FileProvider 触发系统安装；
  /// - Windows：自更新下载的是 setup.exe —— 以 /S 静默安装，应用先落盘再退出，
  ///   由安装器替换文件并自动重启新版（zi_zai_installer.nsi 双用途）；
  /// - macOS/Linux：解压到更新目录并提示手动替换（运行中 .app 无法自替换，见 update.md）。
  Future<void> _installPackage() async {
    final path = widget.updateChecker!.readyPath.value;
    if (path == null) return;
    if (isAndroidPlatform) {
      const channel = MethodChannel('dev.zizai/install');
      await channel.invokeMethod('installApk', {'path': path});
      return;
    }
    if (Platform.isWindows) {
      // 先落盘当前缓冲，再退出；安装器完成静默安装后自动重启新版。
      await widget.library.beforeSwitchSave?.call();
      await widget.logger?.info('update.install.windows', data: {'path': path});
      await Process.start(path, const ['/S']);
      // 给安装器一点启动时间后退出本进程（子进程独立存活，不随父进程终止）。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      exit(0);
    }
    await _extractDesktop(path);
  }

  Future<void> _extractDesktop(String zipPath) async {
    final target = Directory(
      '${widget.updateChecker!.installDir.path}/unpacked',
    );
    // 先清空旧残留：新旧版本文件混在同一 .app 内会破坏 bundle 结构与签名。
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    await target.create(recursive: true);
    if (Platform.isMacOS) {
      // .app 内含符号链接与可执行位，Dart 侧 extractFileToDisk 解压会全部
      // 丢失并使签名失效（替换后系统报「已损坏，无法打开」），
      // 必须用系统 ditto 解压（与 CI 打包 ditto -c -k 对称）。
      final res = await Process.run('ditto', ['-x', '-k', zipPath, target.path]);
      if (res.exitCode != 0) {
        throw UpdateException('解压更新包失败：${res.stderr}');
      }
      // 下载/解压链路可能给产物打上 com.apple.quarantine（历史沙盒版本必打），
      // 带隔离属性的 ad-hoc 签名 .app 会被 Gatekeeper 判「已损坏」拒开，
      // 这里统一剥除；失败不阻塞（非沙盒场景本就无隔离属性）。
      await Process.run('xattr', ['-dr', 'com.apple.quarantine', target.path]);
      const channel = MethodChannel('dev.zizai/open_path');
      await channel.invokeMethod('openPath', {'path': target.path});
    } else {
      await extractFileToDisk(zipPath, target.path);
      if (Platform.isWindows) {
        await Process.run('explorer', [target.path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [target.path]);
      }
    }
  }

  Widget _dbPathRow() {
    final colors = Theme.of(context).colorScheme;
    final path = widget.settings.dbPath;
    return Row(
      children: [
        Expanded(
          child: Text(
            path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ),
        if (!isAndroidPlatform)
          ZzButton.link(label: '打开目录', onPressed: _openDbDir),
      ],
    );
  }

  Widget _logPathRow() {
    final logger = widget.logger!;
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            logger.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ),
        if (isAndroidPlatform)
          ZzButton.link(label: '分享日志', onPressed: _shareLogs)
        else
          ZzButton.link(label: '打开目录', onPressed: _openLogDir),
      ],
    );
  }

  Widget _exportRow() {
    final doc = widget.library.currentDocument;
    final colors = Theme.of(context).colorScheme;
    if (doc == null) {
      return Text(
        '先打开一个文档',
        style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZzButton.primary(
          label: '导出',
          busy: _exporting,
          onPressed: _exporting ? null : _export,
        ),
      ],
    );
  }

  Widget _bookExportRow() {
    final hasChapters = widget.library.notebooks.any(
      (nb) => widget.library.documentsOf(nb.id).isNotEmpty,
    );
    if (!hasChapters) {
      return Text(
        '还没有章节',
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return ZzButton.primary(
      label: '导出全书…',
      onPressed: () =>
          showBookExportDialog(context, library: widget.library),
    );
  }
}

/// 选择器：Notion 式锚定下拉菜单（见 zz.dart ZzSelect）。

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      child: Row(
        children: [
          Text(
            '设置',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: colors.onSurface,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }
}

extension on _SettingsCategory {
  String get label => switch (this) {
    _SettingsCategory.appearance => '外观',
    _SettingsCategory.writing => '写作',
    _SettingsCategory.backup => '备份',
    _SettingsCategory.data => '数据',
    _SettingsCategory.about => '关于',
  };

  String get description => switch (this) {
    _SettingsCategory.appearance => '自定义阅读与编辑体验',
    _SettingsCategory.writing => '管理每日写作目标',
    _SettingsCategory.backup => '安全备份你的作品',
    _SettingsCategory.data => '导出与管理本地数据',
    _SettingsCategory.about => '版本信息与软件更新',
  };

  IconData get icon => switch (this) {
    _SettingsCategory.appearance => Icons.palette_outlined,
    _SettingsCategory.writing => Icons.edit_note_outlined,
    _SettingsCategory.backup => Icons.cloud_outlined,
    _SettingsCategory.data => Icons.folder_outlined,
    _SettingsCategory.about => Icons.info_outline,
  };
}

class _SettingsNav extends StatelessWidget {
  const _SettingsNav({
    required this.selected,
    required this.categories,
    required this.onSelected,
    required this.onReset,
  });

  final _SettingsCategory selected;
  final List<_SettingsCategory> categories;
  final ValueChanged<_SettingsCategory> onSelected;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return SizedBox(
      width: 204,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: appColors.sidebar,
          border: Border(right: BorderSide(color: colors.outline)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(
                  '偏好设置',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: appColors.textTertiary,
                  ),
                ),
              ),
              for (final category in categories) ...[
                if (category == _SettingsCategory.about)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Divider(height: 1, color: colors.outline),
                  ),
                _SettingsNavItem(
                  category: category,
                  selected: selected == category,
                  onTap: () => onSelected(category),
                ),
              ],
              const Spacer(),
              Divider(height: 1, color: colors.outline),
              const SizedBox(height: 8),
              _SettingsNavItem(
                label: '恢复默认',
                icon: Icons.restart_alt,
                onTap: onReset,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsNavItem extends StatefulWidget {
  const _SettingsNavItem({
    this.category,
    required this.onTap,
    this.selected = false,
    this.label,
    this.icon,
  });

  final _SettingsCategory? category;
  final VoidCallback onTap;
  final bool selected;
  final String? label;
  final IconData? icon;

  @override
  State<_SettingsNavItem> createState() => _SettingsNavItemState();
}

class _SettingsNavItemState extends State<_SettingsNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final label = widget.label ?? widget.category!.label;
    final icon = widget.icon ?? widget.category!.icon;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: widget.selected
                ? appColors.rowSelected
                : _hovered
                ? appColors.surfaceHover
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: colors.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: widget.selected
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: widget.selected
                      ? colors.onSurface
                      : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileSettingsNav extends StatelessWidget {
  const _MobileSettingsNav({
    required this.selected,
    required this.categories,
    required this.onSelected,
  });

  final _SettingsCategory selected;
  final List<_SettingsCategory> categories;
  final ValueChanged<_SettingsCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          final category = categories[index];
          final active = category == selected;
          return InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => onSelected(category),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              decoration: BoxDecoration(
                color: active ? appColors.rowSelected : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  category.label,
                  style: TextStyle(
                    fontSize: 13,
                    color: active ? colors.onSurface : colors.onSurfaceVariant,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.category, required this.child});

  final _SettingsCategory category;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 120),
      child: ListView(
        key: ValueKey(category),
        padding: const EdgeInsets.fromLTRB(28, 26, 28, 36),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 580),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category.label,
                  style: TextStyle(
                    fontSize: 22,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.35,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  category.description,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: appColorsOf(context).textTertiary,
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.label,
    required this.control,
    this.description,
  });

  final String label;
  final String? description;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 4,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 13, color: colors.onSurface),
                ),
                if (description != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    description!,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          Flexible(
            flex: 5,
            child: Align(alignment: Alignment.centerRight, child: control),
          ),
        ],
      ),
    );
  }
}

/// 一条快捷键说明：动作名 + 键位（或说明文字）。
class _ShortcutEntry {
  const _ShortcutEntry(this.label, this.keys, {this.secondary, this.note});

  final String label;

  /// 键位块；null = 无键位（仅说明行）。
  final List<String>? keys;

  /// 第二组键位（如「重做」），与第一组以「/」分隔展示。
  final List<String>? secondary;

  /// 无键位时的说明文字（如「加粗走工具栏」）。
  final String? note;
}

/// 快捷键说明面板（design.md §4 Dialog：6px 圆角卡片、文字按钮关闭）。
class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final mod = isMacOS ? '⌘' : 'Ctrl';
    final shift = isMacOS ? '⇧' : 'Shift';
    final groups = <(String, List<_ShortcutEntry>)>[
      (
        '全局',
        [
          _ShortcutEntry('立即保存', [mod, 'S']),
          _ShortcutEntry('切换侧边栏', [mod, 'B']),
          _ShortcutEntry('全书搜索', [mod, 'P']),
          _ShortcutEntry('查找 / 替换（当前文档）', [mod, 'F']),
          _ShortcutEntry('沉浸模式', [mod, shift, 'F']),
          _ShortcutEntry('退出沉浸 / 收起工具栏', ['Esc']),
        ],
      ),
      (
        '编辑',
        [
          _ShortcutEntry('撤销 / 重做', [mod, 'Z'], secondary: [mod, shift, 'Z']),
          _ShortcutEntry('斜体', [mod, 'I']),
          _ShortcutEntry('下划线', [mod, 'U']),
          _ShortcutEntry(
            '加粗',
            null,
            note: '工具栏或选中文本后的浮动菜单（$mod+B 已用于切换侧边栏）',
          ),
        ],
      ),
      (
        '行首输入后按空格',
        [
          _ShortcutEntry('标题 H1–H3', ['#', '##', '###']),
          _ShortcutEntry('无序列表', ['-', '*']),
          _ShortcutEntry('有序列表', ['1.']),
          _ShortcutEntry('引用', ['>']),
          _ShortcutEntry('待办清单', ['[]', '[x]']),
          _ShortcutEntry('代码块', ['```']),
        ],
      ),
      (
        '其它',
        [
          _ShortcutEntry('斜杠命令菜单', ['/']),
          _ShortcutEntry(
            '行内格式',
            ['**加粗**', '*斜体*', '`代码`', '~~删除线~~'],
            note: '输入即渲染',
          ),
        ],
      ),
    ];
    return Dialog(
      child: Container(
        width: 480,
        constraints: const BoxConstraints(maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '快捷键',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                children: [
                  for (final (title, entries) in groups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: appColors.textTertiary,
                        ),
                      ),
                    ),
                    for (final entry in entries) _ShortcutRow(entry: entry),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.entry});

  final _ShortcutEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              entry.label,
              style: TextStyle(fontSize: 13, color: colors.onSurface),
            ),
          ),
          if (entry.keys != null) ...[
            for (final key in entry.keys!) _Kbd(text: key),
            if (entry.secondary != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '/',
                  style: TextStyle(
                    fontSize: 12,
                    color: appColors.textTertiary,
                  ),
                ),
              ),
              for (final key in entry.secondary!) _Kbd(text: key),
            ],
          ] else if (entry.note != null)
            Flexible(
              child: Text(
                entry.note!,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 12,
                  color: appColors.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 键位块：bg-hover 底 + hairline 描边，4px 圆角。
class _Kbd extends StatelessWidget {
  const _Kbd({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: appColors.surfaceHover,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: colors.outline),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: colors.onSurface,
          ),
        ),
      ),
    );
  }
}

class _MobileSettingsFooter extends StatelessWidget {
  const _MobileSettingsFooter({required this.onReset, required this.onClose});

  final VoidCallback onReset;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outline)),
      ),
      child: Row(
        children: [
          ZzButton.link(label: '恢复默认', onPressed: onReset),
          const Spacer(),
          ZzButton.primary(label: '关闭', onPressed: onClose),
        ],
      ),
    );
  }
}
