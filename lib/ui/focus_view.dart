/// 沉浸模式包装：隐藏 chrome 的全屏编辑 + 平台退出机制。
///
/// 设计依据：docs/app/ui-editor.md FocusMode 细节（桌面 Esc / 顶缘悬停退出条；
/// Android 系统返回为主 + 顶部 48px 热区兜底：点按弹「退出+字数」条、下滑直接退；
/// 热区不拦截编辑区滚动；Android 沉浸时字数隐藏，点热区才显示）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../util/platform.dart';

class FocusView extends StatelessWidget {
  const FocusView({
    super.key,
    required this.focusMode,
    required this.onExit,
    required this.liveWords,
    required this.fallbackWords,
    required this.todayDelta,
    required this.dailyGoal,
    required this.child,
  });

  final bool focusMode;
  final VoidCallback onExit;

  /// 实时字数（逐键更新，只有字数条订阅，避免沉浸态全树重建）。
  final ValueListenable<int?> liveWords;

  /// liveWords 为 null 时的保存快照回退。
  final int fallbackWords;
  final int todayDelta;
  final int dailyGoal;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!focusMode) return child;
    return PopScope(
      // Android 系统返回/返回键：拦截 → 退出沉浸，不退出 App。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onExit();
      },
      child: Stack(
        children: [
          Positioned.fill(child: child),
          if (isAndroidPlatform)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _AndroidHotZone(
                onExit: onExit,
                liveWords: liveWords,
                fallbackWords: fallbackWords,
                todayDelta: todayDelta,
                dailyGoal: dailyGoal,
              ),
            )
          else
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _DesktopExitStrip(onExit: onExit),
            ),
        ],
      ),
    );
  }
}

/// Android 顶部 48px 热区：点按弹「退出 + 字数」条；下滑直接退出。
class _AndroidHotZone extends StatefulWidget {
  const _AndroidHotZone({
    required this.onExit,
    required this.liveWords,
    required this.fallbackWords,
    required this.todayDelta,
    required this.dailyGoal,
  });

  final VoidCallback onExit;
  final ValueListenable<int?> liveWords;
  final int fallbackWords;
  final int todayDelta;
  final int dailyGoal;

  @override
  State<_AndroidHotZone> createState() => _AndroidHotZoneState();
}

class _AndroidHotZoneState extends State<_AndroidHotZone> {
  bool _showBar = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => setState(() => _showBar = !_showBar),
          onVerticalDragEnd: (details) {
            if (details.primaryVelocity != null && details.primaryVelocity! > 0) {
              widget.onExit();
            }
          },
          child: const SizedBox(height: 48, width: double.infinity),
        ),
        if (_showBar)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.outline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<int?>(
                  valueListenable: widget.liveWords,
                  builder: (context, live, _) => Text(
                    '本文 ${live ?? widget.fallbackWords} 字 · '
                    '今日 ${widget.todayDelta}/${widget.dailyGoal}',
                    style: TextStyle(fontSize: 13, color: colors.onSurface),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(onPressed: widget.onExit, child: const Text('退出')),
              ],
            ),
          ),
      ],
    );
  }
}

/// 桌面顶缘悬停退出条：hover 出现「退出 + Esc 提示」。
class _DesktopExitStrip extends StatefulWidget {
  const _DesktopExitStrip({required this.onExit});

  final VoidCallback onExit;

  @override
  State<_DesktopExitStrip> createState() => _DesktopExitStripState();
}

class _DesktopExitStripState extends State<_DesktopExitStrip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: _hover ? 40 : 16,
        alignment: Alignment.center,
        child: _hover
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.outline),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('退出沉浸 (Esc)', style: TextStyle(fontSize: 12, color: colors.onSurface)),
                    const SizedBox(width: 8),
                    TextButton(onPressed: widget.onExit, child: const Text('退出')),
                  ],
                ),
              )
            : null,
      ),
    );
  }
}
