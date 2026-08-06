/// 设置页：外观 / 写作 / 数据 三区（同步区归 sync-ui-003，关于区归 upd-001）。
///
/// 设计依据：docs/app/ui-settings.md（Region Layout / Interactions /
/// State Variants / Component Tree）、docs/app/style.md（§3 tokens、§5 尺寸、
/// §6 圆角阴影）、docs/app/README.md §8（平台差异：桌面保存对话框 /
/// Android 系统分享）。
library;

import 'dart:io';

import 'package:archive/archive_io.dart' show extractFileToDisk;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:share_plus/share_plus.dart';

import '../app.dart' show appColorsOf;
import '../core/backup/backup.dart';
import '../core/export.dart' show exportPlainText;
import '../core/models.dart';
import '../core/update.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import '../util/platform.dart';

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

class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.settings,
    required this.library,
    this.backup,
    this.updateChecker,
    this.dbSchemaVersion,
    this.exporter,
    this.autoFocusDailyGoal = false,
    this.autoFocusSync = false,
  });

  final SettingsController settings;
  final LibraryController library;

  /// 备份引擎（null = 未接线，如单测；备份区隐藏）。
  final BackupManager? backup;

  /// 更新检查（null = 未接线，如单测；关于区隐藏更新按钮）。
  final UpdateChecker? updateChecker;

  /// 本地 DB schema 版本（关于区展示）。
  final int? dbSchemaVersion;

  /// 导出实现（null = 默认：桌面 getSaveLocation 写 .txt / Android 分享）。
  final ExportHandler? exporter;

  /// 打开时聚焦「每日目标字数」（状态栏今日进度点击入口）。
  final bool autoFocusDailyGoal;

  /// 打开时定位「同步」区（状态栏同步指示点击入口）。
  final bool autoFocusSync;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  String? _exportError;
  bool _exporting = false;
  String? _installNote;
  final FocusNode _goalFocus = FocusNode();
  late final TextEditingController _goalController = TextEditingController(
    text: widget.settings.settings.dailyGoal.toString(),
  );

  Settings get _s => widget.settings.settings;

  @override
  void initState() {
    super.initState();
    if (widget.autoFocusDailyGoal) {
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
    _updateUrlController.dispose();
    super.dispose();
  }

  void _update(Settings next) => widget.settings.update(next);

  Future<void> _export() async {
    final doc = widget.library.currentDocument;
    if (doc == null) return;
    final text = exportPlainText(doc);
    setState(() {
      _exporting = true;
      _exportError = null;
    });
    try {
      final handler = widget.exporter ?? _defaultExport;
      await handler(doc, text);
    } catch (e) {
      setState(() => _exportError = '导出失败: $e');
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
    if (Platform.isMacOS) {
      await Process.run('open', [dir]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [dir]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [dir]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(onClose: () => Navigator.of(context).maybePop()),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  children: [
                    _Section(
                      '外观',
                      icon: Icons.palette_outlined,
                      children: [
                        _row('主题', _themePicker()),
                        _row('字体', _fontPicker()),
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
                    _Section(
                      '写作',
                      icon: Icons.edit_note_outlined,
                      children: [_row('每日目标字数', _goalField())],
                    ),
                    if (widget.backup != null) ...[
                      _Section(
                        '备份',
                        icon: Icons.cloud_outlined,
                        children: [
                          _row('Account ID', _backupAccountField()),
                          _row('Bucket', _backupBucketField()),
                          _row('Access Key', _backupAccessField()),
                          _row('Secret Key', _backupSecretField()),
                          _row('上次备份', _lastBackupRow()),
                          _backupActions(),
                        ],
                      ),
                    ],
                    _Section(
                      '数据',
                      icon: Icons.folder_outlined,
                      children: [
                        _row('数据库路径', _dbPathRow()),
                        _row('导出当前文档', _exportRow()),
                      ],
                    ),
                    if (widget.updateChecker != null)
                      _Section(
                        '关于',
                        icon: Icons.info_outline,
                        children: [
                          _row(
                            'App 版本',
                            Text(
                              widget.updateChecker!.appVersion,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          _row(
                            '数据库版本',
                            Text(
                              'schema v${widget.dbSchemaVersion ?? 0}',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          _row('更新地址', _updateUrlField()),
                          _row('检查更新', _checkUpdateRow()),
                        ],
                      ),
                  ],
                ),
              ),
              _ActionsRow(
                onReset: () => _update(const Settings()),
                onDone: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(String label, Widget control) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                height: 1.25,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: control),
        ],
      ),
    );
  }

  Widget _themePicker() {
    return _ValuePicker<String>(
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
    return _ValuePicker<String>(
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
          child: CupertinoSlider(
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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

  Widget _goalField() {
    // 外部（恢复默认等）变更时同步输入框内容；聚焦时不动。
    final current = _s.dailyGoal.toString();
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
        _update(_s.copyWith(dailyGoal: n));
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

  /// iOS 风格输入框（hairline 描边、圆角 6、placeholder 用次要文字色）。
  Widget _notionField({
    required TextEditingController controller,
    required String hint,
    bool obscure = false,
    TextInputType? keyboardType,
    FocusNode? focusNode,
    required ValueChanged<String> onSubmitted,
  }) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return CupertinoTextField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: keyboardType,
      obscureText: obscure,
      style: TextStyle(fontSize: 13, color: colors.onSurface),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: appColors.callout,
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(7),
      ),
      placeholder: hint,
      placeholderStyle: TextStyle(fontSize: 13, color: appColors.textTertiary),
      cursorColor: colors.primary,
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
                _SettingsButton.primary(
                  label: '上传备份',
                  busy: backup.state.value == BackupState.uploading,
                  onPressed: (!configured || busy) ? null : _runUpload,
                ),
                const SizedBox(width: 8),
                _SettingsButton.secondary(
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
                child: _SettingsButton.link(
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
    await widget.backup!.upload();
  }

  /// 下载恢复会覆盖本地数据 → 二次确认；恢复后刷新库与设置控制器。
  Future<void> _confirmDownload() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('下载恢复'),
        content: const Text(
          '将用云端备份覆盖本地全部数据。\n'
          '本地数据会先自动备份为 .bak 文件（保留最近 3 份），仍可找回。',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await widget.backup!.download();
    if (ok && mounted) {
      await widget.library.restore();
      await widget.settings.load();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已从云端备份恢复')));
      }
    }
  }

  late final TextEditingController _updateUrlController = TextEditingController(
    text: widget.updateChecker?.updateUrl ?? '',
  );

  Widget _updateUrlField() {
    return _notionField(
      controller: _updateUrlController,
      hint: 'https://…/zizai/apps/update.json',
      onSubmitted: (v) => widget.settings.db.setSetting('update.url', v.trim()),
    );
  }

  /// 检查更新：accent 徽标 + 确认下载 + 进度 + 安装（ui-settings.md 关于区）。
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _SettingsButton.primary(
                  label: label,
                  busy: downloading,
                  onPressed: downloading ? null : () => _runUpdateCheck(),
                ),
                if (downloading && checker.progress.value != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      '下载中 ${(checker.progress.value! * 100).round()}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
            if (checker.error.value != null)
              Text(
                checker.error.value!,
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            if (checker.readyPath.value != null && _installNote == null)
              Text(
                '安装包已就绪：${checker.readyPath.value}',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            if (_installNote != null)
              Text(
                _installNote!,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
          ],
        );
      },
    );
  }

  Future<void> _runUpdateCheck() async {
    final checker = widget.updateChecker!;
    try {
      switch (checker.status.value) {
        case UpdateStatus.none || UpdateStatus.error:
          await checker.check(); // 第一步：发现新版 → available（待确认）
        case UpdateStatus.available:
          await checker.install(); // 第二步：确认下载 → 校验 → ready
        case UpdateStatus.ready:
          await _installPackage(); // 已就绪：执行平台安装/解压
        case UpdateStatus.downloading:
          break; // 进行中
      }
    } catch (_) {
      // 错误已入 checker.error
    }
  }

  /// 平台安装：Android 经 FileProvider 触发系统安装；桌面解压到更新目录并提示
  /// （运行中 .app 无法自替换，自用 V1 给出路径 + 手动替换说明，见 update.md）。
  Future<void> _installPackage() async {
    final path = widget.updateChecker!.readyPath.value;
    if (path == null) return;
    if (isAndroidPlatform) {
      const channel = MethodChannel('dev.zizai/install');
      await channel.invokeMethod('installApk', {'path': path});
    } else {
      await _extractDesktop(path);
    }
  }

  Future<void> _extractDesktop(String zipPath) async {
    final target = Directory(
      '${widget.updateChecker!.installDir.path}/unpacked',
    );
    await target.create(recursive: true);
    await extractFileToDisk(zipPath, target.path);
    if (mounted) {
      setState(
        () => _installNote =
            '安装包已解压：${target.path}\n'
            '请替换应用目录后重启（macOS 未签名 App 首次需右键打开）',
      );
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
          _SettingsButton.link(label: '打开目录', onPressed: _openDbDir),
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
        _SettingsButton.primary(
          label: '导出',
          busy: _exporting,
          onPressed: _exporting ? null : _export,
        ),
        if (_exportError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _InlineNote(
              text: _exportError!,
              color: colors.error,
              icon: Icons.error_outline,
            ),
          ),
      ],
    );
  }
}

/// iOS 风格选择器：显示当前值，点按弹 CupertinoActionSheet。
class _ValuePicker<T> extends StatelessWidget {
  const _ValuePicker({
    required this.value,
    required this.display,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final String display;
  final List<({String label, T value})> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: () async {
        final picked = await showCupertinoModalPopup<T>(
          context: context,
          builder: (context) => CupertinoActionSheet(
            actions: [
              for (final o in options)
                CupertinoActionSheetAction(
                  isDefaultAction: o.value == value,
                  onPressed: () => Navigator.of(context).pop(o.value),
                  child: Text(o.label),
                ),
            ],
            cancelButton: CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ),
        );
        if (picked != null) onChanged(picked);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              display,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: colors.onSurface),
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right, size: 14, color: colors.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 10, 12),
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

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.icon, required this.children});

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: appColors.textTertiary),
              const SizedBox(width: 7),
              Text(
                title,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _InlineNote extends StatelessWidget {
  const _InlineNote({
    required this.text,
    required this.color,
    required this.icon,
  });

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, height: 1.35, color: color),
          ),
        ),
      ],
    );
  }
}

class _SettingsButton extends StatelessWidget {
  const _SettingsButton._({
    required this.label,
    required this.onPressed,
    required this.variant,
    this.color,
    this.busy = false,
  });

  factory _SettingsButton.primary({
    required String label,
    required VoidCallback? onPressed,
    bool busy = false,
  }) => _SettingsButton._(
    label: label,
    onPressed: onPressed,
    variant: _SettingsButtonVariant.primary,
    busy: busy,
  );

  factory _SettingsButton.secondary({
    required String label,
    required VoidCallback? onPressed,
    Color? color,
    bool busy = false,
  }) => _SettingsButton._(
    label: label,
    onPressed: onPressed,
    variant: _SettingsButtonVariant.secondary,
    color: color,
    busy: busy,
  );

  factory _SettingsButton.link({
    required String label,
    required VoidCallback? onPressed,
    Color? color,
  }) => _SettingsButton._(
    label: label,
    onPressed: onPressed,
    variant: _SettingsButtonVariant.link,
    color: color,
  );

  final String label;
  final VoidCallback? onPressed;
  final _SettingsButtonVariant variant;
  final Color? color;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final enabled = onPressed != null && !busy;
    final foreground =
        color ??
        (variant == _SettingsButtonVariant.primary
            ? colors.onPrimary
            : colors.onSurfaceVariant);
    final background = switch (variant) {
      _SettingsButtonVariant.primary => colors.primary,
      _SettingsButtonVariant.secondary => appColors.callout,
      _SettingsButtonVariant.link => Colors.transparent,
    };
    final border = switch (variant) {
      _SettingsButtonVariant.primary => colors.primary,
      _SettingsButtonVariant.secondary => colors.outline,
      _SettingsButtonVariant.link => Colors.transparent,
    };
    return CupertinoButton(
      minimumSize: Size.zero,
      padding: EdgeInsets.zero,
      onPressed: enabled ? onPressed : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: variant == _SettingsButtonVariant.link
            ? const EdgeInsets.symmetric(horizontal: 2, vertical: 4)
            : const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: enabled ? background : appColors.callout,
          border: Border.all(
            color: enabled ? border : colors.outline.withValues(alpha: 0.6),
          ),
          borderRadius: BorderRadius.circular(7),
        ),
        child: busy
            ? SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: variant == _SettingsButtonVariant.primary
                      ? colors.onPrimary
                      : colors.primary,
                ),
              )
            : Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                  color: enabled
                      ? foreground
                      : colors.onSurfaceVariant.withValues(alpha: 0.45),
                ),
              ),
      ),
    );
  }
}

enum _SettingsButtonVariant { primary, secondary, link }

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({required this.onReset, required this.onDone});

  final VoidCallback onReset;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: colors.outline)),
      ),
      child: Row(
        children: [
          _SettingsButton.link(label: '恢复默认', onPressed: onReset),
          const Spacer(),
          _SettingsButton.primary(label: '完成', onPressed: onDone),
        ],
      ),
    );
  }
}
