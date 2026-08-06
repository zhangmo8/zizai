/// 主界面壳：侧边栏区域 + 编辑器区 + 状态栏，宽度自适应切换形态。
///
/// 设计依据：docs/app/ui-shell.md（Region Layout / State Variants /
/// Interactions：Ctrl/Cmd+B 切换侧边栏、删除确认条在编辑器区顶部）、
/// docs/app/style.md（§3 tokens、§5 尺寸、§9 组件样式）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import 'sidebar.dart';
import 'status_bar.dart';

const double _desktopSidebarWidth = 240;
const double _androidDrawerWidth = 360;
const double _desktopBreakpoint = 800;

class Shell extends StatefulWidget {
  const Shell({super.key, required this.library, required this.settings});

  final LibraryController library;
  final SettingsController settings;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  bool _sidebarVisible = true;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.library, widget.settings]),
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= _desktopBreakpoint;
            final editor = _EditorArea(
              library: widget.library,
              settings: widget.settings,
            );
            final sidebar = Sidebar(library: widget.library);
            if (desktop) {
              // 桌面形态无 Scaffold，需显式 Material 祖先（InkWell/TextButton 依赖）。
              return _withShortcuts(
                Material(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_sidebarVisible) ...[
                        SizedBox(width: _desktopSidebarWidth, child: sidebar),
                        const VerticalDivider(width: 1),
                      ],
                      Expanded(child: editor),
                    ],
                  ),
                ),
              );
            }
            // Android 形态：Drawer 左滑入（含遮罩），编辑器全宽。
            return Scaffold(
              drawer: Drawer(width: _androidDrawerWidth, child: sidebar),
              body: editor,
            );
          },
        );
      },
    );
  }

  /// 桌面全局快捷键：Ctrl/Cmd+B 切换侧边栏显隐（ui-shell.md Interactions）。
  Widget _withShortcuts(Widget child) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.keyB &&
            (HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed)) {
          setState(() => _sidebarVisible = !_sidebarVisible);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

/// 编辑器区：顶部删除确认条（非模态，5s 自动关）+ 内容 + 状态栏。
class _EditorArea extends StatelessWidget {
  const _EditorArea({required this.library, required this.settings});

  final LibraryController library;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (library.pendingDeletion != null)
          _DeleteBar(
            request: library.pendingDeletion!,
            onCancel: library.cancelDelete,
            onConfirm: library.confirmDelete,
          ),
        Expanded(
          child: library.loading
              ? const Center(child: Text('载入中…'))
              : library.currentDocument == null
                  ? Center(
                      child: Text(
                        '从这里开始写…',
                        style: TextStyle(
                          fontSize: 16,
                          fontStyle: FontStyle.italic,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                        library.currentDocument!.title,
                        style: TextStyle(fontSize: 24, color: colors.onSurface),
                      ),
                    ),
        ),
        StatusBar(library: library, settings: settings),
      ],
    );
  }
}

/// 删除确认条：编辑器区顶部通条，danger 色 + 确认/取消，5s 无操作自动关。
class _DeleteBar extends StatefulWidget {
  const _DeleteBar({
    required this.request,
    required this.onCancel,
    required this.onConfirm,
  });

  final DeletionRequest request;
  final VoidCallback onCancel;
  final Future<void> Function() onConfirm;

  @override
  State<_DeleteBar> createState() => _DeleteBarState();
}

class _DeleteBarState extends State<_DeleteBar> {
  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 5), widget.onCancel);
  }

  late Timer _timer;

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colors.errorContainer.withValues(alpha: 0.35),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.warning_amber_outlined, size: 16, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '删除《${widget.request.name}》？此操作不可恢复',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: colors.onErrorContainer),
            ),
          ),
          TextButton(onPressed: widget.onCancel, child: const Text('取消')),
          TextButton(
            onPressed: () => widget.onConfirm(),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }
}
