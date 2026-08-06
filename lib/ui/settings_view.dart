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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:share_plus/share_plus.dart';

import '../core/export.dart' show exportPlainText;
import '../core/models.dart';
import '../core/sync/client.dart';
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
    this.syncClient,
    this.updateChecker,
    this.dbSchemaVersion,
    this.exporter,
    this.autoFocusDailyGoal = false,
    this.autoFocusSync = false,
  });

  final SettingsController settings;
  final LibraryController library;

  /// 同步引擎（null = 未接线，如单测；同步区隐藏）。
  final SyncClient? syncClient;

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
  late final TextEditingController _goalController =
      TextEditingController(text: widget.settings.settings.dailyGoal.toString());

  Settings get _s => widget.settings.settings;

  @override
  void initState() {
    super.initState();
    if (widget.autoFocusDailyGoal) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goalFocus.requestFocus());
    }
  }

  @override
  void dispose() {
    _goalFocus.dispose();
    _goalController.dispose();
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(onClose: () => Navigator.of(context).maybePop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                children: [
                  _Section('外观', children: [
                    _row('主题', _themePicker()),
                    _row('字体', _fontPicker()),
                    _row('字号', _slider(
                      12, 28, _s.fontSize, 1,
                      (v) => _update(_s.copyWith(fontSize: v)),
                      '${_s.fontSize.round()}',
                    )),
                    _row('行距', _slider(
                      1.2, 2.4, _s.lineHeight, 0.1,
                      (v) => _update(_s.copyWith(lineHeight: v)),
                      _s.lineHeight.toStringAsFixed(1),
                    )),
                    _preview(),
                  ]),
                  _Section('写作', children: [
                    _row('每日目标字数', _goalField()),
                  ]),
                  if (widget.syncClient != null) ...[
                    _Section('同步', children: [
                      _row('云同步', _syncToggle()),
                      _row('同步地址', _syncUrlField()),
                      _row('同步令牌', _syncTokenField()),
                      _row('上次同步', _lastSyncRow()),
                      _syncActions(),
                      if (widget.syncClient!.conflictBackups.value > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '有 ${widget.syncClient!.conflictBackups.value} 份本地版本已备份于 '
                            '${widget.syncClient!.backupDir.path}/sync-bak，可在云端版本控制找回',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ]),
                  ],
                  _Section('数据', children: [
                    _row('数据库路径', _dbPathRow()),
                    _row('导出当前文档', _exportRow()),
                  ]),
                  if (widget.updateChecker != null) _Section('关于', children: [
                    _row('App 版本', Text(
                      widget.updateChecker!.appVersion,
                      style: const TextStyle(fontSize: 13),
                    )),
                    _row('数据库版本', Text(
                      'schema v${widget.dbSchemaVersion ?? 0}',
                      style: const TextStyle(fontSize: 13),
                    )),
                    _row('更新地址', _updateUrlField()),
                    _row('检查更新', _checkUpdateRow()),
                  ]),
                  if (_exportError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _exportError!,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  _ActionsRow(
                    onReset: () => _update(const Settings()),
                    onDone: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _row(String label, Widget control) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
          ),
          Expanded(child: control),
        ],
      ),
    );
  }

  Widget _themePicker() {
    return DropdownButton<String>(
      value: _s.theme,
      isExpanded: true,
      items: const [
        DropdownMenuItem(value: 'system', child: Text('跟随系统')),
        DropdownMenuItem(value: 'light', child: Text('浅色')),
        DropdownMenuItem(value: 'dark', child: Text('深色')),
      ],
      onChanged: (v) {
        if (v != null) _update(_s.copyWith(theme: v));
      },
    );
  }

  Widget _fontPicker() {
    return DropdownButton<String>(
      value: _s.fontFamily,
      isExpanded: true,
      items: [
        for (final f in kFontChoices)
          DropdownMenuItem(value: f, child: Text(f.isEmpty ? '系统默认' : f)),
      ],
      onChanged: (v) {
        if (v != null) _update(_s.copyWith(fontFamily: v));
      },
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
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            label: label,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(label, textAlign: TextAlign.right, style: const TextStyle(fontSize: 13)),
        ),
      ],
    );
  }

  /// 示例文本预览：字号/行距/字体实时作用于编辑器同款样式。
  Widget _preview() {
    final s = _s;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(6),
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
    return TextField(
      controller: _goalController,
      focusNode: _goalFocus,
      keyboardType: TextInputType.number,
      style: const TextStyle(fontSize: 13),
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        hintText: '100–50000',
      ),
      onSubmitted: (v) {
        final n = int.tryParse(v.trim());
        if (n == null || n < 100 || n > 50000) return;
        _update(_s.copyWith(dailyGoal: n));
      },
    );
  }

  // ── 同步区（sync-ui-003）──────────────────────────────────

  late final TextEditingController _syncUrlController = TextEditingController(
      text: widget.syncClient?.baseUrl ?? '');
  late final TextEditingController _syncTokenController = TextEditingController();

  Widget _syncToggle() {
    final sync = widget.syncClient!;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        return Switch(
          value: sync.enabled,
          onChanged: (v) => sync.setEnabled(v),
        );
      },
    );
  }

  Widget _syncUrlField() {
    return TextField(
      controller: _syncUrlController,
      style: const TextStyle(fontSize: 13),
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        hintText: 'https://zizai-sync.xxx.workers.dev',
      ),
      onSubmitted: (v) => widget.syncClient!.setBaseUrl(v.trim()),
    );
  }

  Widget _syncTokenField() {
    return TextField(
      controller: _syncTokenController,
      obscureText: true, // 掩码显示；token 仅存本地 settings 表
      style: const TextStyle(fontSize: 13),
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        hintText: 'Worker secret（SYNC_TOKEN）',
      ),
      onSubmitted: (v) => widget.syncClient!.setToken(v.trim()),
    );
  }

  Widget _lastSyncRow() {
    final sync = widget.syncClient!;
    return ListenableBuilder(
      listenable: sync.lastSyncAt,
      builder: (context, _) {
        final at = sync.lastSyncAt.value;
        return Text(
          at == null ? '从未同步' : '${_relativeTime(at)}（${at.toLocal()}）',
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
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

  Widget _syncActions() {
    final sync = widget.syncClient!;
    return ListenableBuilder(
      listenable: Listenable.merge([sync.state, sync.failureCount, sync.lastError]),
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final syncing = sync.state.value == SyncState.syncing;
        final error = sync.lastError.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: syncing ? null : () => sync.syncNow(),
                  child: syncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('立即同步'),
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
            if (error != null && !syncing)
              TextButton(
                onPressed: () => sync.syncNow(),
                style: TextButton.styleFrom(foregroundColor: colors.error),
                child: const Text('重试'),
              ),
          ],
        );
      },
    );
  }

  late final TextEditingController _updateUrlController = TextEditingController(
      text: widget.updateChecker?.updateUrl ?? '');

  Widget _updateUrlField() {
    return TextField(
      controller: _updateUrlController,
      style: const TextStyle(fontSize: 13),
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        hintText: 'https://…/zizai/apps/update.json',
      ),
      onSubmitted: (v) => widget.settings.db.setSetting('update.url', v.trim()),
    );
  }

  /// 检查更新：accent 徽标 + 确认下载 + 进度 + 安装（ui-settings.md 关于区）。
  Widget _checkUpdateRow() {
    final checker = widget.updateChecker!;
    return ListenableBuilder(
      listenable: Listenable.merge([checker.status, checker.error, checker.progress]),
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        final status = checker.status.value;
        final downloading = status == UpdateStatus.downloading;
        final available = status == UpdateStatus.ready;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: downloading ? null : () => _runUpdateCheck(),
                  style: available
                      ? FilledButton.styleFrom(backgroundColor: colors.primary)
                      : null,
                  child: downloading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(available ? '有新版，点击安装' : '检查更新'),
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
      await checker.checkForUpdate();
      if (checker.status.value == UpdateStatus.ready) {
        await _installPackage();
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
        '${widget.updateChecker!.installDir.path}/unpacked');
    await target.create(recursive: true);
    await extractFileToDisk(zipPath, target.path);
    if (mounted) {
      setState(() => _installNote = '安装包已解压：${target.path}\n'
          '请替换应用目录后重启（macOS 未签名 App 首次需右键打开）');
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
          TextButton(onPressed: _openDbDir, child: const Text('打开目录')),
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
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.tonal(
        onPressed: _exporting ? null : _export,
        child: _exporting
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('导出'),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 8, 8),
      child: Row(
        children: [
          Text(
            '设置',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: colors.onSurface),
          ),
          const Spacer(),
          IconButton(onPressed: onClose, icon: const Icon(Icons.close), tooltip: '关闭'),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          ...children,
          Divider(height: 24, color: Theme.of(context).dividerColor),
        ],
      ),
    );
  }
}

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({required this.onReset, required this.onDone});

  final VoidCallback onReset;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        TextButton(
          onPressed: onReset,
          style: TextButton.styleFrom(foregroundColor: colors.onSurfaceVariant),
          child: const Text('恢复默认'),
        ),
        const Spacer(),
        FilledButton(onPressed: onDone, child: const Text('完成')),
      ],
    );
  }
}
