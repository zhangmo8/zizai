/// Liquid Glass 面板：BackdropFilter 模糊 + 半透明填充 + hairline 描边。
///
/// macOS 26 / iOS 26 风格核心组件；所有浮层/面板/状态条走玻璃，
/// 不再使用 Material 的 elevation 阴影层级。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// 玻璃面板。light 下为白色半透明、dark 下为黑色半透明（Apple 双态玻璃）。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.blur = 24,
    this.radius = 0,
    this.lightOpacity = 0.68,
    this.darkOpacity = 0.10,
    this.border,
    this.padding,
  });

  final Widget child;
  final double blur;

  /// 圆角（0 = 直角面板，如侧边栏/状态条）。
  final double radius;

  /// light 下白色填充不透明度。
  final double lightOpacity;

  /// dark 下白色填充不透明度（白微透玻璃）。
  final double darkOpacity;

  /// 描边（默认无；侧边栏传 `Border(right: ...)`）。
  final Border? border;

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // light：白玻璃（68%）；dark：白 10% 微透玻璃 —— 在深灰底上形成可见面板层次，
    // 而不是黑底黑玻璃的"虚无"。
    final fill = (dark ? Colors.white : Colors.white)
        .withValues(alpha: dark ? darkOpacity : lightOpacity);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(radius),
            border: border,
            // 玻璃面板顶部 0.5px 高光（Apple 质感细节）。
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                (dark ? Colors.white : Colors.white)
                    .withValues(alpha: dark ? 0.06 : 0.12),
                Colors.transparent,
              ],
              stops: const [0, 0.3],
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
