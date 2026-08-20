/// 主界面壳：侧边栏区域 + 编辑器区，宽度自适应切换形态。
///
/// 设计依据：docs/app/ui-shell.md（Region Layout / Interactions：
/// Ctrl/Cmd+B 切换侧边栏、删除确认条在编辑器区顶部）、
/// docs/app/ui-editor.md（FocusMode：沉浸隐藏侧边栏与状态栏；Esc 收起工具栏）、
/// design.md（Notion token、侧边栏和组件样式）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart' show appColorsOf;
import '../core/backup/backup.dart';
import '../core/app_logger.dart';
import '../core/book_search.dart';
import '../core/crash_journal.dart';
import '../core/snapshot_history.dart';
import '../core/update.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import '../util/ime_state.dart';
import '../util/platform.dart';
import 'book_search_dialog.dart';
import 'editor.dart';
import 'glass.dart';
import 'settings_view.dart';
import 'sidebar.dart';

const double _desktopSidebarWidth = 260;
const double _androidDrawerWidth = 340;
const double _desktopBreakpoint = 800;

class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.library,
    required this.settings,
    this.journal,
    this.logger,
    this.backup,
    this.updateChecker,
    this.snapshots,
  });

  final LibraryController library;
  final SettingsController settings;

  /// 崩溃日志（null = 未接线，如测试）。
  final CrashJournal? journal;

  /// 本地诊断日志（null = 未接线，如测试）。
  final AppLogger? logger;

  /// 同步引擎（null = 未接线，如测试）。
  final BackupManager? backup;

  /// 更新检查（null = 未接线，如测试）。
  final UpdateChecker? updateChecker;

  /// 单文档版本历史（null = 未接线，如测试）。
  final SnapshotHistory? snapshots;

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
  final ValueNotifier<int> _findTick = ValueNotifier(0);

  /// 全书搜索命中 → 编辑器定位请求（editor 消费后清空）。
  final ValueNotifier<EditorJumpRequest?> _jumpRequest = ValueNotifier(null);
  bool _bookSearchOpen = false;
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
    _findTick.dispose();
    _jumpRequest.dispose();
    if (_lifecycleObserver != null) {
      WidgetsBinding.instance.removeObserver(_lifecycleObserver!);
    }
    super.dispose();
  }

  bool _onGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    // IME 组合阶段（拼音未确认）不处理任何快捷键，避免误触保存/查找/侧栏。
    if (isImeComposing) return false;
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
    if (key == LogicalKeyboardKey.keyF && mod) {
      // 必须在此层拦截：焦点在 Quill 编辑器内时，flutter_quill 内置的
      // Ctrl/Cmd+F 会抢先弹出其自带搜索对话框（未接本地化 → 空白遮罩）。
      _findTick.value++;
      return true;
    }
    if (key == LogicalKeyboardKey.keyP && mod) {
      // 沉浸模式保持无打扰：吞掉但不弹（Cmd+P 无系统默认行为）。
      if (!_focusMode) _openBookSearch();
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

  /// 全书搜索：命中点击 → 下发跳转请求，必要时切换文档。
  ///
  /// 切换文档会因 EditorView 的 key 换新编辑器实例，请求须在切换前就位，
  /// 由新实例 initState 消费；同文档跳转则由现编辑器的 listener 消费。
  Future<void> _openBookSearch() async {
    if (_bookSearchOpen) return;
    _bookSearchOpen = true;
    try {
      await showBookSearchDialog(
        context,
        library: widget.library,
        onOpen: (BookSearchHit hit) async {
          _jumpRequest.value = EditorJumpRequest(
            documentId: hit.documentId,
            offset: hit.offset,
            length: hit.length,
          );
          if (widget.library.currentDocument?.id != hit.documentId) {
            await widget.library.switchDocument(hit.documentId);
          }
        },
      );
    } finally {
      _bookSearchOpen = false;
    }
  }

  /// 设置的唯一打开出口：侧边栏底部、状态栏的定向入口共用。
  void _openSettings({bool focusDailyGoal = false, bool focusBackup = false}) {
    final view = SettingsView(
      settings: widget.settings,
      library: widget.library,
      backup: widget.backup,
      logger: widget.logger,
      updateChecker: widget.updateChecker,
      dbSchemaVersion: widget.updateChecker?.dbSchemaVersion,
      autoFocusDailyGoal: focusDailyGoal,
      autoFocusBackup: focusBackup,
    );
    if (isAndroidPlatform) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => Scaffold(body: view),
        ),
      );
    } else {
      showDialog<void>(
        context: context,
        builder: (_) =>
            Dialog(child: SizedBox(width: 840, height: 620, child: view)),
      );
    }
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
              key: ValueKey(
                widget.library.currentDocument?.id ?? 'no-document',
              ),
              library: widget.library,
              settings: widget.settings,
              focusMode: _focusMode,
              onToggleFocusMode: () => setState(() => _focusMode = !_focusMode),
              onOpenSettings: _openSettings,
              backup: widget.backup,
              toolbarDismissTick: _toolbarDismissTick,
              saveTick: _saveTick,
              findTick: _findTick,
              journal: widget.journal,
              logger: widget.logger,
              snapshots: widget.snapshots,
              jumpRequest: _jumpRequest,
            );
            final sidebar = Sidebar(
              library: widget.library,
              onOpenSettings: _openSettings,
              onOpenBookSearch: _openBookSearch,
            );
            if (desktop) {
              // 桌面形态无 Scaffold，需显式 Material 祖先；Notion 风格为固定
              // 低对比侧栏 + 干净纸张编辑区，不使用渐变/毛玻璃。
              final appColors = appColorsOf(context);
              return Material(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_sidebarVisible && !_focusMode) ...[
                      SizedBox(
                        width: _desktopSidebarWidth,
                        child: GlassSurface(
                          color: appColors.sidebar,
                          border: Border(
                            right: BorderSide(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                          child: sidebar,
                        ),
                      ),
                    ],
                    Expanded(child: editor),
                  ],
                ),
              );
            }
            // Android 形态：Drawer 左滑入（含遮罩），编辑器全宽。
            return Scaffold(
              drawer: _focusMode
                  ? null
                  : Drawer(width: _androidDrawerWidth, child: sidebar),
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
