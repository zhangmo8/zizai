/// 状态栏：今日进度 + 本文字数 + 已保存闪 + 保存失败重试。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;
import '../core/backup/backup.dart';
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

    final goal = widget.settings.settings.dailyGoal;
    final delta = widget.library.todayDelta;
    final progress = goal <= 0 ? 0.0 : (delta / goal).clamp(0.0, 1.0);

    return GlassSurface(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      border: Border(top: BorderSide(color: colors.outline)),
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            _StatusChip(
              onTap: () => widget.onOpenSettings?.call(focusDailyGoal: true),
              child: Text('今日 $delta/$goal'),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 104,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  color: colors.primary,
                  backgroundColor: colors.outline.withValues(alpha: 0.55),
                ),
              ),
            ),
            const Spacer(),
            if (widget.backup != null)
              _BackupIndicator(
                backup: widget.backup!,
                onTap: () => widget.onOpenSettings?.call(focusBackup: true),
              ),
            if (_showSaved)
              Text(
                '已保存',
                style: TextStyle(
                  fontSize: 12,
                  color: appColors.success,
                  fontWeight: FontWeight.w600,
                ),
              )
            else
              // 字数逐键变化，用 ValueListenableBuilder 局部刷新，
              // 不惊动状态栏之外的任何子树。
              ValueListenableBuilder<int?>(
                valueListenable: widget.library.liveWords,
                builder: (context, live, _) {
                  final words =
                      live ?? widget.library.currentDocument?.words ?? 0;
                  return Text(
                    '本文 $words 字',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  );
                },
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
        borderRadius: BorderRadius.circular(5),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: _hover ? appColors.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
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

class _BackupIndicator extends StatelessWidget {
  const _BackupIndicator({required this.backup, required this.onTap});

  final BackupManager backup;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return ListenableBuilder(
      listenable: backup,
      builder: (context, _) {
        if (!backup.configured) return const SizedBox.shrink();
        final (icon, text, color) = switch (backup.state.value) {
          BackupState.uploading => ('⟳', '备份中', colors.onSurfaceVariant),
          BackupState.downloading => ('⟳', '恢复中', colors.onSurfaceVariant),
          BackupState.error => (
            '⚠',
            '失败 ${backup.failureCount.value} 次',
            colors.error,
          ),
          BackupState.idle => ('●', '已备份', appColors.success),
        };
        return _StatusChip(
          onTap: onTap,
          child: Text('$icon $text', style: TextStyle(color: color)),
        );
      },
    );
  }
}
