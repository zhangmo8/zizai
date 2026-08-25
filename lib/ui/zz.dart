/// Zz 共享控件（Notion 风格）：下拉选择、开关、滑杆、按钮、输入框、确认弹窗、toast。
///
/// 设计依据：design.md §2-§4（token、圆角三档 4/6/8、控件规范）。
/// 全部为自绘/Material 实现，不引入任何 Cupertino 组件。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;

// ── 下拉选择（替代 CupertinoActionSheet 选择器）──────────────

/// 锚定在触发器下方的下拉菜单：6px 圆角浮层、条目 hover 高亮、当前项 ✓。
class ZzSelect<T> extends StatelessWidget {
  const ZzSelect({
    super.key,
    required this.value,
    required this.display,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final String display;
  final List<({String label, T value})> options;
  final ValueChanged<T> onChanged;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final colors = Theme.of(context).colorScheme;
    final picked = await showMenu<T>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + box.size.height + 4,
        overlay.size.width - origin.dx - box.size.width,
        0,
      ),
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 280),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      items: [
        for (final o in options)
          PopupMenuItem<T>(
            value: o.value,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    o.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: colors.onSurface),
                  ),
                ),
                if (o.value == value)
                  Icon(Icons.check, size: 15, color: colors.onSurface),
              ],
            ),
          ),
      ],
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return _HoverBox(
      borderRadius: 4,
      onTap: () => _open(context),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
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
          const SizedBox(width: 5),
          Icon(Icons.expand_more, size: 14, color: appColors.textTertiary),
        ],
      ),
    );
  }
}

// ── 开关 ─────────────────────────────────────────────────────

/// 小型 toggle（30×18）：off 灰 / on accent，120ms 位移动画。
class ZzSwitch extends StatelessWidget {
  const ZzSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: 30,
          height: 18,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: value
                ? colors.primary
                : colors.onSurface.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(9),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 14,
              height: 14,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── 滑杆 ─────────────────────────────────────────────────────

/// 细轨道 4px + 12px 圆点滑杆（替代 CupertinoSlider）。
class ZzSlider extends StatelessWidget {
  const ZzSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: colors.primary,
        inactiveTrackColor: colors.onSurface.withValues(alpha: 0.12),
        thumbColor: Colors.white,
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: 6,
          elevation: 1,
          pressedElevation: 2,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        overlayColor: colors.primary.withValues(alpha: 0.08),
        tickMarkShape: SliderTickMarkShape.noTickMark,
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    );
  }
}

// ── 按钮 ─────────────────────────────────────────────────────

enum ZzButtonVariant { primary, secondary, link }

/// Notion 式按钮：primary accent 底 / secondary 边框 / link 纯文字，
/// busy 时按钮内 spinner 替换文字（异步反馈规范 design.md §5.4）。
class ZzButton extends StatefulWidget {
  const ZzButton._({
    required this.label,
    required this.onPressed,
    required this.variant,
    this.color,
    this.busy = false,
  });

  factory ZzButton.primary({
    required String label,
    required VoidCallback? onPressed,
    bool busy = false,
  }) => ZzButton._(
    label: label,
    onPressed: onPressed,
    variant: ZzButtonVariant.primary,
    busy: busy,
  );

  factory ZzButton.secondary({
    required String label,
    required VoidCallback? onPressed,
    Color? color,
    bool busy = false,
  }) => ZzButton._(
    label: label,
    onPressed: onPressed,
    variant: ZzButtonVariant.secondary,
    color: color,
    busy: busy,
  );

  factory ZzButton.link({
    required String label,
    required VoidCallback? onPressed,
    Color? color,
  }) => ZzButton._(
    label: label,
    onPressed: onPressed,
    variant: ZzButtonVariant.link,
    color: color,
  );

  final String label;
  final VoidCallback? onPressed;
  final ZzButtonVariant variant;
  final Color? color;
  final bool busy;

  @override
  State<ZzButton> createState() => _ZzButtonState();
}

class _ZzButtonState extends State<ZzButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final enabled = widget.onPressed != null && !widget.busy;
    final primary = widget.variant == ZzButtonVariant.primary;
    final link = widget.variant == ZzButtonVariant.link;
    final foreground =
        widget.color ?? (primary ? colors.onPrimary : colors.onSurfaceVariant);
    Color background;
    if (!enabled) {
      background = link ? Colors.transparent : appColors.callout;
    } else if (primary) {
      background = _pressed
          ? Color.alphaBlend(Colors.black26, colors.primary)
          : _hover
          ? Color.alphaBlend(Colors.black12, colors.primary)
          : colors.primary;
    } else if (link) {
      background = _hover ? appColors.surfaceHover : Colors.transparent;
    } else {
      background = _pressed
          ? appColors.rowSelected
          : _hover
          ? appColors.surfaceHover
          : appColors.callout;
    }
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: link
              ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: background,
            border: link || primary
                ? null
                : Border.all(
                    color: enabled
                        ? colors.outline
                        : colors.outline.withValues(alpha: 0.6),
                  ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: widget.busy
              ? SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: primary ? colors.onPrimary : colors.primary,
                  ),
                )
              : Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                    color: enabled
                        ? foreground
                        : colors.onSurfaceVariant.withValues(alpha: 0.45),
                  ),
                ),
        ),
      ),
    );
  }
}

// ── 输入框 ───────────────────────────────────────────────────

/// Notion 式输入框：浅底、无边框，focus 时 accent 1px 描边。
///
/// 全应用统一入口：单行默认 28–32px 垂直居中，多行（[expands] 或
/// [maxLines]>1）顶对齐；空 hint 转 null，避免空字符串 hint 让文本下移
/// ~1.6px 破坏与同行按钮的水平居中对齐。
class ZzTextField extends StatelessWidget {
  const ZzTextField({
    super.key,
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.keyboardType,
    this.focusNode,
    this.enabled = true,
    this.autofocus = false,
    this.error = false,
    this.compact = false,
    this.maxLines = 1,
    this.expands = false,
    this.fontSize = 13,
    this.lineHeight,
    this.contentPadding,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.onEditingComplete,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final FocusNode? focusNode;
  final bool enabled;
  final bool autofocus;
  final bool compact;

  /// 错误态：描边转 danger（行内命名冲突等即时校验用）。
  final bool error;

  /// 行数：1 = 单行；null / [expands] = 多行文本区。
  final int? maxLines;

  /// 填满父级高度（配合 `maxLines: null`，如章节备注面板）。
  final bool expands;

  /// 字号（默认 13；查找条用 12.5）。
  final double fontSize;

  /// 行高倍数（仅多行文本区常用，如备注面板 1.6）。
  final double? lineHeight;

  /// 内部内边距（默认 水平 8、垂直 0 —— 垂直 0 保证单行文本在定高内居中）。
  final EdgeInsets? contentPadding;

  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final radius = BorderRadius.circular(4);
    final singleLine = !expands && maxLines == 1;
    // 空 hint 转 null：InputDecorator 遇到空字符串 hintText 会额外保留
    // 垂直空间，把文本整体下移 ~1.6px，与同行按钮不再水平居中。
    final resolvedHint = hint.isEmpty ? null : hint;
    final field = TextField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: keyboardType,
      obscureText: obscure,
      enabled: enabled,
      autofocus: autofocus,
      maxLines: expands ? null : maxLines,
      expands: expands,
      textInputAction: textInputAction,
      // 单行垂直居中、多行顶对齐 —— 统一处理所有输入框的对齐。
      textAlignVertical: singleLine
          ? TextAlignVertical.center
          : TextAlignVertical.top,
      style: TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        color: colors.onSurface,
      ),
      cursorColor: colors.primary,
      cursorWidth: 2,
      cursorRadius: const Radius.circular(1),
      decoration: InputDecoration(
        // 不用 isDense：isDense 会把单行文本往上推 ~4px（Flutter 行为），
        // 破坏水平居中对齐；改用 vertical:0 contentPadding 居中。
        filled: true,
        fillColor: appColors.callout,
        hintText: resolvedHint,
        hintStyle: TextStyle(
          fontSize: fontSize,
          color: appColors.textTertiary,
        ),
        contentPadding:
            contentPadding ?? const EdgeInsets.symmetric(horizontal: 8),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: error ? BorderSide(color: colors.error) : BorderSide.none,
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: error ? colors.error : colors.primary),
        ),
      ),
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      onEditingComplete: onEditingComplete,
    );
    // 高度规则（design.md §4：控件 28–32px）：父给有界高度则继承，
    // 与同行按钮等元素天然对齐；否则回退 compact 28 / 常规 32 定高。
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : (compact ? 28.0 : 32.0);
        return SizedBox(height: height, child: field);
      },
    );
  }
}

// ── 确认弹窗 ─────────────────────────────────────────────────

/// 居中小卡片确认弹窗（替代 CupertinoAlertDialog）。返回 true = 确认。
Future<bool> zzConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String cancelLabel = '取消',
  String confirmLabel = '确认',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final colors = Theme.of(context).colorScheme;
      return AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: colors.outline),
        ),
        insetPadding: const EdgeInsets.all(24),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Text(message, style: const TextStyle(height: 1.5)),
        ),
        actions: [
          ZzButton.link(
            label: cancelLabel,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          ZzButton.link(
            label: confirmLabel,
            color: danger ? colors.error : colors.primary,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      );
    },
  );
  return result == true;
}

// ── Toast ────────────────────────────────────────────────────

OverlayEntry? _activeToast;

/// 底部居中 toast：深底白字，2.5s 自动消失（异步操作结果反馈）。
/// 基于 Overlay，不依赖 Scaffold（桌面壳层无 Scaffold）。
void showZzToast(BuildContext context, String message, {bool error = false}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _activeToast?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      return Positioned(
        bottom: 56,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, (1 - t) * 8),
                  child: child,
                ),
              ),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 560),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: dark
                      ? const Color(0xFF3A3A38)
                      : const Color(0xFF37352F),
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1A000000),
                      blurRadius: 12,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (error) ...[
                      const Icon(
                        Icons.error_outline,
                        size: 15,
                        color: Color(0xFFFF7369),
                      ),
                      const SizedBox(width: 7),
                    ],
                    Flexible(
                      child: Text(
                        message,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  _activeToast = entry;
  overlay.insert(entry);
  Future<void>.delayed(const Duration(milliseconds: 2500), () {
    if (_activeToast == entry) {
      _activeToast = null;
      entry.remove();
    }
  });
}

// ── 图标按钮 ─────────────────────────────────────────────────

/// 图标按钮（Notion chrome）：28×28、4px 圆角，tertiary icon（hover 转
/// primary 文字色），hover/pressed 背景反馈；**必须带 tooltip**（§4/§5.4）。
class ZzIconButton extends StatefulWidget {
  const ZzIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = 18,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;

  @override
  State<ZzIconButton> createState() => _ZzIconButtonState();
}

class _ZzIconButtonState extends State<ZzIconButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.onPressed != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.onPressed == null
              ? null
              : (_) => setState(() => _pressed = true),
          onTapUp: widget.onPressed == null
              ? null
              : (_) => setState(() => _pressed = false),
          onTapCancel: widget.onPressed == null
              ? null
              : () => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _pressed
                  ? appColors.rowSelected
                  : _hover
                  ? appColors.surfaceHover
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              widget.icon,
              size: widget.size,
              color: _hover ? colors.onSurface : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// ── 内部：hover 反馈容器 ─────────────────────────────────────

class _HoverBox extends StatefulWidget {
  const _HoverBox({
    required this.child,
    required this.onTap,
    required this.borderRadius,
    this.padding,
  });

  final Widget child;
  final VoidCallback onTap;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  State<_HoverBox> createState() => _HoverBoxState();
}

class _HoverBoxState extends State<_HoverBox> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final appColors = appColorsOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: _hover ? appColors.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
