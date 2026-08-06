/// 主界面壳：侧边栏区域 + 编辑器区，宽度自适应切换形态。
///
/// 设计依据：docs/app/ui-shell.md（Region Layout / Interactions：
/// Ctrl/Cmd+B 切换侧边栏、删除确认条在编辑器区顶部）、
/// docs/app/ui-editor.md（FocusMode：沉浸隐藏侧边栏与状态栏；Esc 收起工具栏）、
/// docs/app/style.md（§3 tokens、§5 尺寸、§9 组件样式）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/backup/backup.dart';
import '../core/crash_journal.dart';
import '../core/update.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import 'editor.dart';
import 'glass.dart';
import 'sidebar.dart';

const double _desktopSidebarWidth = 240;
const double _androidDrawerWidth = 360;
const double _desktopBreakpoint = 800;

class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.library,
    required this.settings,
    this.journal,
    this.backup,
    this.updateChecker,
  });

  final LibraryController library;
  final SettingsController settings;

  /// 崩溃日志（null = 未接线，如测试）。
  final CrashJournal? journal;

  /// 同步引擎（null = 未接线，如测试）。
  final BackupManager? backup;

  /// 更新检查（null = 未接线，如测试）。
  final UpdateChecker? updateChecker;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  bool _sidebarVisible = true;
  bool _focusMode = false;

  /// 通知编辑器收起上下文工具栏（Esc 全局处理，与焦点无关）。
  final ValueNotifier<int> _toolbarDismissTick = ValueNotifier(0);

  /// 通知编辑器立即保存（Ctrl/Cmd+S 全局处理：Windows 下 flutter_quill
  /// 内置 Ctrl+S=codeBlock 会遮蔽编辑器层快捷键，全局 handler 先于其分发）。
  final ValueNotifier<int> _saveTick = ValueNotifier(0);
  WidgetsBindingObserver? _lifecycleObserver;

  @override
  void initState() {
    super.initState();
    // 全局快捷键走 HardwareKeyboard：不依赖焦点子树，测试与真实环境一致。
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    // App 退到后台立即保存（自动保存优先，防丢）。
    _lifecycleObserver = _SaveOnPauseObserver(widget.library);
    WidgetsBinding.instance.addObserver(_lifecycleObserver!);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _toolbarDismissTick.dispose();
    _saveTick.dispose();
    if (_lifecycleObserver != null) {
      WidgetsBinding.instance.removeObserver(_lifecycleObserver!);
    }
    super.dispose();
  }

  bool _onGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    final kb = HardwareKeyboard.instance;
    final mod = kb.isControlPressed || kb.isMetaPressed;
    if (key == LogicalKeyboardKey.keyS && mod) {
      _saveTick.value++; // 立即保存（UI 自动保存防抖照常）
      return true;
    }
    if (key == LogicalKeyboardKey.keyB && mod) {
      setState(() => _sidebarVisible = !_sidebarVisible);
      return true;
    }
    if (key == LogicalKeyboardKey.keyF && mod && kb.isShiftPressed) {
      setState(() => _focusMode = !_focusMode);
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_focusMode) {
        setState(() => _focusMode = false);
        return true;
      }
      // 非沉浸：收起工具栏；不消费事件，让框架继续（对话框 Esc 关闭等）。
      _toolbarDismissTick.value++;
      return false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.library, widget.settings]),
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= _desktopBreakpoint;
            final editor = EditorView(
              library: widget.library,
              settings: widget.settings,
              focusMode: _focusMode,
              onToggleFocusMode: () => setState(() => _focusMode = !_focusMode),
              backup: widget.backup,
              updateChecker: widget.updateChecker,
              toolbarDismissTick: _toolbarDismissTick,
              saveTick: _saveTick,
              journal: widget.journal,
            );
            final sidebar = Sidebar(library: widget.library);
            if (desktop) {
              // 桌面形态无 Scaffold，需显式 Material 祖先；窗口底 = 极淡纵向渐变
              // （Apple 背景气质），侧边栏为 Liquid Glass 面板。
              final dark = Theme.of(context).brightness == Brightness.dark;
              return Material(
                color: Colors.transparent,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: dark
                          ? const [Color(0xFF242426), Color(0xFF1C1C1E)]
                          : const [Color(0xFFFFFFFF), Color(0xFFF5F5F7)],
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_sidebarVisible && !_focusMode) ...[
                        SizedBox(
                          width: _desktopSidebarWidth,
                          child: GlassSurface(
                            border: Border(
                              right: BorderSide(
                                color: Theme.of(context).colorScheme.outline,
                                width: 0.5,
                              ),
                            ),
                            child: sidebar,
                          ),
                        ),
                      ],
                      Expanded(child: editor),
                    ],
                  ),
                ),
              );
            }
            // Android 形态：Drawer 左滑入（含遮罩），编辑器全宽。
            return Scaffold(
              drawer: _focusMode ? null : Drawer(width: _androidDrawerWidth, child: sidebar),
              body: editor,
            );
          },
        );
      },
    );
  }
}

/// App 退到后台立即保存当前缓冲。
class _SaveOnPauseObserver with WidgetsBindingObserver {
  _SaveOnPauseObserver(this.library);

  final LibraryController library;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      library.beforeSwitchSave?.call();
    }
  }
}
