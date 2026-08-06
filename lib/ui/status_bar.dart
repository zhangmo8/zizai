/// 状态栏：今日进度 + 本文字数 + 已保存闪 + 保存失败重试。
///
/// 设计依据：docs/app/ui-shell.md（状态栏区域、Interactions）、
/// docs/app/ui-editor.md（状态栏内容、Ctrl+S 闪「已保存」、自动保存失败错误条）、
/// docs/app/style.md（§3 tokens、§9 组件样式）。同步指示由 sync-ui-003 接入。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../state/settings_controller.dart';

class StatusBar extends StatefulWidget {
  const StatusBar({
    super.key,
    required this.library,
    required this.settings,
    this.onRetrySave,
  });

  final LibraryController library;
  final SettingsController settings;

  /// 保存失败「重试」回调（editor 注入；null 时不显示重试）。
  final Future<void> Function()? onRetrySave;

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

    return Container(
      height: 32,
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 16),
          Text(
            '今日 $delta/$goal',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
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
    );
  }
}
