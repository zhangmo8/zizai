/// Notion 风格面板：实色 surface + subtle border。
///
/// 保留 `GlassSurface` 名称以减少调用侧改动；实现已从 Liquid Glass
/// 切换为 Notion-inspired flat surface，不再使用毛玻璃/高光。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;

class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.blur = 0,
    this.radius = 0,
    this.lightOpacity = 1,
    this.darkOpacity = 1,
    this.border,
    this.padding,
    this.color,
    this.shadow = false,
  });

  final Widget child;

  /// 兼容旧调用参数；Notion flat surface 不使用 blur。
  final double blur;
  final double radius;
  final double lightOpacity;
  final double darkOpacity;
  final Border? border;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? appColorsOf(context).surfaceRaised,
        borderRadius: BorderRadius.circular(radius),
        border: border,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: colors.outline.withValues(alpha: 0.35),
                  blurRadius: 0,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}
