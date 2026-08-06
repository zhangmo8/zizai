/// 状态栏：今日进度 + 本文字数 + 已保存闪 + 保存失败重试。
///
/// 设计依据：docs/app/ui-shell.md（状态栏区域、Interactions）、
/// docs/app/ui-editor.md（状态栏内容、Ctrl+S 闪「已保存」、自动保存失败错误条）、
/// docs/app/style.md（§3 tokens、§9 组件样式）。同步指示由 sync-ui-003 接入。
library;

import 'dart:async';

import 'package:flutter/material.dart';

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

  /// 备份引擎（null = 未接线，如单测；备份指示隐藏）。
  final BackupManager? backup;

  /// 保存失败「重试」回调（editor 注入；null 时不显示重试）。
  final Future<void> Function()? onRetrySave;

  /// 点击今日进度 / 同步状态点 → 打开设置（ui-shell.md Interactions）。
  final void Function({bool focusDailyGoal, bool focusSync})? onOpenSettings;

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

  /// Ctrl+S / 自动保存成功 → 闪「已保存」1s。
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
    final error = widget.library.saveError;

    // 保存失败：错误条 + 重试（缓冲保留在编辑器内存）。
    if (error != null) {
      return Container(
        height: 32,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor, width: 1),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
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
    final words = widget.library.liveDocWords ??
        widget.library.currentDocument?.words ??
        0;

    return GlassSurface(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      blur: 20,
      lightOpacity: 0.55,
      darkOpacity: 0.10,
      border: Border(
        top: BorderSide(
          color: Theme.of(context).colorScheme.outline,
          width: 0.5,
        ),
      ),
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            const SizedBox(width: 0),
            InkWell(
              onTap: () => widget.onOpenSettings?.call(focusDailyGoal: true),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '今日 $delta/$goal',
                  style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: ClipRRect(
                borderRadius: BorderRadius.zero,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 2,
                  color: colors.primary,
                backgroundColor: colors.outline.withValues(alpha: 0.4),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(progress * 100).round()}%',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          const Spacer(),
          if (widget.backup != null)
            _BackupIndicator(
              backup: widget.backup!,
              onTap: () => widget.onOpenSettings?.call(focusSync: true),
            ),
          if (_showSaved)
            Text(
              '已保存',
              style: TextStyle(
                fontSize: 12,
                color: colors.primary,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            Text(
              '本文 $words 字',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          const SizedBox(width: 16),
        ],
        ),
      ),
    );
  }
}

/// 备份状态点：● 已备份 / ⟳ 备份中 / ⚠ 失败 n 次；未配置凭据时不显示。
class _BackupIndicator extends StatelessWidget {
  const _BackupIndicator({required this.backup, required this.onTap});

  final BackupManager backup;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: backup,
      builder: (context, _) {
        if (!backup.configured) return const SizedBox.shrink();
        final (icon, text, color) = switch (backup.state.value) {
          BackupState.uploading => ('⟳', '备份中', colors.onSurfaceVariant),
          BackupState.downloading => ('⟳', '恢复中', colors.onSurfaceVariant),
          BackupState.error => ('⚠', '失败 ${backup.failureCount.value} 次', colors.error),
          BackupState.idle => ('●', '已备份', colors.primary),
        };
        return InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              '$icon $text',
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        );
      },
    );
  }
}
