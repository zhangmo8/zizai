/// 状态栏：今日进度 + 本文字数（同步指示由 sync-ui-003 接入）。
///
/// 设计依据：docs/app/ui-shell.md（状态栏区域、交互）、docs/app/ui-editor.md
/// （状态栏内容）、docs/app/style.md（§3 tokens、§9 组件样式）。
library;

import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../state/settings_controller.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.library, required this.settings});

  final LibraryController library;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final error = library.error;
    if (error != null) {
      // 存储错误：状态栏左侧红色错误条，点击重试（ui-shell State Variants）。
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
            TextButton(
              onPressed: () {
                library.clearError();
                library.retry();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final goal = settings.settings.dailyGoal;
    final delta = library.todayDelta;
    final progress = goal <= 0 ? 0.0 : (delta / goal).clamp(0.0, 1.0);
    final words = library.currentDocument?.words ?? 0;

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
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurfaceVariant,
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
