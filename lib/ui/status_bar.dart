/// 状态栏：今日进度 + 本文字数 + 已保存闪 + 保存失败重试。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;
import '../core/backup/backup.dart';
import '../core/writing_session.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import 'glass.dart';

class StatusBar extends StatefulWidget {
  const StatusBar({
    super.key,
    required this.library,
    required this.settings,
    this.backup,
    this.onRetrySave,
    this.onOpenSettings,
  });

  final LibraryController library;
  final SettingsController settings;
  final BackupManager? backup;
  final Future<void> Function()? onRetrySave;
  final void Function({bool focusDailyGoal, bool focusBackup})? onOpenSettings;

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  Timer? _flashTimer;
  bool _showSaved = false;

  @override
  void initState() {
    super.initState();
    widget.library.savedAt.addListener(_onSaved);
  }

  @override
  void didUpdateWidget(covariant StatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.savedAt.removeListener(_onSaved);
      widget.library.savedAt.addListener(_onSaved);
    }
  }

  @override
  void dispose() {
    widget.library.savedAt.removeListener(_onSaved);
    _flashTimer?.cancel();
    super.dispose();
  }

  void _onSaved() {
    _flashTimer?.cancel();
    setState(() => _showSaved = true);
    _flashTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _showSaved = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final error = widget.library.saveError;

    if (error != null) {
      return Container(
        height: 34,
        decoration: BoxDecoration(
          color: appColors.callout,
          border: Border(top: BorderSide(color: colors.outline)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 14, color: colors.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                error,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            ),
            if (widget.onRetrySave != null)
              TextButton(
                onPressed: () => widget.onRetrySave!(),
                child: const Text('重试'),
              ),
          ],
        ),
      );
    }

    final notebookId = widget.library.currentDocument?.notebookId;
    final goal = widget.settings.goalForNotebook(notebookId);
    final delta = widget.library.todayDelta;
    final progress = (delta / goal.words).clamp(0.0, 1.0);

    return GlassSurface(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      border: Border(top: BorderSide(color: colors.outline)),
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            if (goal.enabled && notebookId != null) ...[
              // 左侧组也需可收缩：窄窗下目标 chip 文本 ellipsis，
              // 否则与固定 104px 进度条一起把整行挤爆（toast 下方黄线）。
              Flexible(
                child: _StatusChip(
                  onTap: () =>
                      widget.onOpenSettings?.call(focusDailyGoal: true),
                  child: Text(
                    '今日 $delta/${goal.words}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 104,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    color: colors.primary,
                    backgroundColor: colors.outline.withValues(alpha: 0.55),
                  ),
                ),
              ),
            ],
            const Spacer(),
            // 右侧组整体放入 Flexible：窄窗口（手机 / 桌面拖窄）时内部
            // 文本截断而非溢出（黄线防护；状态栏常驻底部，最易触发）。
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.max,
                children: [
                  Flexible(
                    child: _SessionChip(session: widget.library.session),
                  ),
                  if (widget.backup != null)
                    _BackupIndicator(
                      backup: widget.backup!,
                      onTap: () =>
                          widget.onOpenSettings?.call(focusBackup: true),
                    ),
                  Flexible(
                    child: _showSaved
                        ? Text(
                            '已保存',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: appColors.success,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        // 字数逐键变化，用 ValueListenableBuilder 局部刷新，
                        // 不惊动状态栏之外的任何子树。
                        : ValueListenableBuilder<int?>(
                            valueListenable: widget.library.liveWords,
                            builder: (context, live, _) {
                              final words = live ??
                                  widget.library.currentDocument?.words ??
                                  0;
                              return Text(
                                '本文 $words 字',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatefulWidget {
  const _StatusChip({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_StatusChip> createState() => _StatusChipState();
}

class _StatusChipState extends State<_StatusChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: _hover ? appColors.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// 写作会话条：本次字数 / 时长 / 速度。仅在本次有新增字数时显示。
///
/// 活跃时每 30 秒自动刷新时长；订阅 [WritingSession] 局部重建，不影响状态栏其余部分。
class _SessionChip extends StatefulWidget {
  const _SessionChip({required this.session});

  final WritingSession session;

  @override
  State<_SessionChip> createState() => _SessionChipState();
}

class _SessionChipState extends State<_SessionChip> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onChanged);
    _scheduleTick();
  }

  @override
  void didUpdateWidget(covariant _SessionChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onChanged);
      widget.session.addListener(_onChanged);
      _scheduleTick();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.session.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
      _scheduleTick();
    }
  }

  /// 活跃会话每 30s 刷新一次时长显示。
  void _scheduleTick() {
    _tick?.cancel();
    if (!widget.session.active) return;
    _tick = Timer(const Duration(seconds: 30), () {
      if (mounted) {
        setState(() {});
        _scheduleTick();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.session.snapshot;
    if (snap.words == 0) return const SizedBox.shrink();
    final appColors = appColorsOf(context);
    final duration = formatSessionDuration(snap.duration);
    final wph = snap.wordsPerHour;
    final tooltip = '本次写作 +${snap.words} 字 · $duration'
        '${wph > 0 ? ' · $wph 字/小时' : ''}';
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Text(
          '+${snap.words} · $duration${wph > 0 ? ' · $wph/时' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: appColors.success,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _BackupIndicator extends StatelessWidget {
  const _BackupIndicator({required this.backup, required this.onTap});

  final BackupManager backup;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([
        backup,
        backup.state,
        backup.lastBackupAt,
        backup.failureCount,
      ]),
      builder: (context, _) {
        if (!backup.configured) return const SizedBox.shrink();
        final (icon, text, color) = switch (backup.state.value) {
          BackupState.uploading => (
            Icons.cloud_upload_outlined,
            '备份中',
            colors.onSurfaceVariant,
          ),
          BackupState.downloading => (
            Icons.cloud_download_outlined,
            '恢复中',
            colors.onSurfaceVariant,
          ),
          BackupState.error => (
            Icons.sync_problem_outlined,
            '失败 ${backup.failureCount.value} 次',
            colors.error,
          ),
          BackupState.idle when backup.lastBackupAt.value == null => (
            Icons.cloud_outlined,
            '未备份',
            colors.onSurfaceVariant,
          ),
          BackupState.idle => (
            Icons.cloud_done_outlined,
            '已备份',
            appColors.success,
          ),
        };
        return Tooltip(
          message: text,
          child: _StatusChip(
            onTap: onTap,
            child: Icon(icon, size: 15, color: color),
          ),
        );
      },
    );
  }
}
