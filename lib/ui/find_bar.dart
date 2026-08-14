/// 查找/替换条：编辑区右上角浮层（当前文档范围）。
///
/// 设计依据：docs/app/ui-editor.md §查找与替换、design.md（Notion token、
/// 圆角 6px、icon 带 tooltip、hover 反馈）。匹配/替换逻辑在编辑器侧
/// （core/find.dart 纯函数 + QuillController），本组件只承载输入与动作。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart' show appColorsOf;
import 'glass.dart';

class FindBar extends StatefulWidget {
  const FindBar({
    super.key,
    required this.matchCount,
    required this.currentIndex,
    required this.onQueryChanged,
    required this.onNext,
    required this.onPrev,
    required this.onReplace,
    required this.onReplaceAll,
    required this.onClose,
    this.initialQuery = '',
  });

  /// 当前匹配总数；[currentIndex] 为激活匹配下标（-1 = 无）。
  final int matchCount;
  final int currentIndex;
  final String initialQuery;

  final void Function(String query) onQueryChanged;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final void Function(String replacement) onReplace;
  final void Function(String replacement) onReplaceAll;
  final VoidCallback onClose;

  @override
  State<FindBar> createState() => FindBarState();
}

class FindBarState extends State<FindBar> {
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );
  final TextEditingController _replacement = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  bool _showReplace = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _queryFocus.requestFocus();
      _query.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _query.text.length,
      );
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _replacement.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  /// 外部（Ctrl/Cmd+F 重复触发）要求重新聚焦查找框。
  void focusQuery() {
    _queryFocus.requestFocus();
    _query.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _query.text.length,
    );
  }

  Widget _iconBtn({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
    bool active = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? appColors.rowSelected : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            size: 15,
            color: onTap == null
                ? appColors.textTertiary
                : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    FocusNode? focusNode,
    void Function(String)? onChanged,
    void Function()? onSubmit,
    void Function()? onShiftSubmit,
  }) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return SizedBox(
      width: 168,
      height: 28,
      child: Focus(
        onKeyEvent: (_, event) {
          // Shift+Enter → 上一个（TextField 自身只回调 onSubmitted）。
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.enter &&
              HardwareKeyboard.instance.isShiftPressed &&
              onShiftSubmit != null) {
            onShiftSubmit();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          onSubmitted: onSubmit == null ? null : (_) => onSubmit(),
          maxLines: 1,
          style: TextStyle(fontSize: 12.5, color: colors.onSurface),
          cursorColor: colors.primary,
          cursorWidth: 2,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: TextStyle(
              fontSize: 12.5,
              color: appColors.textTertiary,
            ),
            filled: true,
            fillColor: appColors.callout,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: colors.primary),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final hasQuery = _query.text.isNotEmpty;
    final hasMatch = widget.matchCount > 0;
    final counter = !hasQuery
        ? ''
        : hasMatch
        ? '${widget.currentIndex + 1}/${widget.matchCount}'
        : '无结果';
    return GlassSurface(
      radius: 6,
      shadow: true,
      color: appColors.surfaceRaised,
      border: Border.all(color: colors.outline),
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _iconBtn(
                icon: _showReplace ? Icons.expand_less : Icons.expand_more,
                tooltip: _showReplace ? '收起替换' : '展开替换',
                active: _showReplace,
                onTap: () => setState(() => _showReplace = !_showReplace),
              ),
              const SizedBox(width: 4),
              _field(
                controller: _query,
                hint: '查找',
                focusNode: _queryFocus,
                onChanged: (v) {
                  widget.onQueryChanged(v);
                  setState(() {}); // 计数/按钮态刷新
                },
                onSubmit: widget.onNext,
                onShiftSubmit: widget.onPrev,
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 52,
                child: Text(
                  counter,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: hasMatch
                        ? colors.onSurfaceVariant
                        : appColors.textTertiary,
                  ),
                ),
              ),
              _iconBtn(
                icon: Icons.keyboard_arrow_up,
                tooltip: '上一个 (Shift+Enter)',
                onTap: hasMatch ? widget.onPrev : null,
              ),
              _iconBtn(
                icon: Icons.keyboard_arrow_down,
                tooltip: '下一个 (Enter)',
                onTap: hasMatch ? widget.onNext : null,
              ),
              _iconBtn(
                icon: Icons.close,
                tooltip: '关闭 (Esc)',
                onTap: widget.onClose,
              ),
            ],
          ),
          if (_showReplace) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 30),
                _field(
                  controller: _replacement,
                  hint: '替换为',
                  onSubmit: () => widget.onReplace(_replacement.text),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: hasMatch
                      ? () => widget.onReplace(_replacement.text)
                      : null,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                  ),
                  child: const Text('替换', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: hasMatch
                      ? () => widget.onReplaceAll(_replacement.text)
                      : null,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                  ),
                  child: const Text('全部替换', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
