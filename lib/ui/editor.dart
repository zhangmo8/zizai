/// 所见即所得编辑器：Quill 编辑器 + 上下文工具栏 + 自动保存 + 字数。
///
/// 设计依据：docs/app/ui-editor.md（Region Layout / Interactions /
/// Word Count / State Variants）、docs/app/style.md（§3 tokens、§4 字体、
/// §5 尺寸、§9 组件样式）、docs/app/README.md §7（自动保存优先、无模态打断）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_quill/flutter_quill.dart' as q;

import '../app.dart' show appColorsOf;
import '../core/crash_journal.dart';
import '../core/export.dart' show emptyDeltaJson, parseDeltaOps;
import '../core/models.dart' as m;
import '../core/word_count.dart';
import '../core/backup/backup.dart';
import '../core/update.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import '../util/debounce.dart';
import '../util/platform.dart';
import 'focus_view.dart';
import 'glass.dart';
import 'settings_view.dart';
import 'status_bar.dart';

const int _autoSaveDebounceMs = 1000;
const int _journalThrottleMs = 500;
const double _maxContentWidth = 760;
const double _contentVPadding = 88;

class EditorView extends StatefulWidget {
  const EditorView({
    super.key,
    required this.library,
    required this.settings,
    required this.focusMode,
    required this.onToggleFocusMode,
    this.backup,
    this.updateChecker,
    this.toolbarDismissTick,
    this.saveTick,
    this.journal,
  });

  final LibraryController library;
  final SettingsController settings;
  final bool focusMode;
  final VoidCallback onToggleFocusMode;

  /// Esc 收起工具栏通知（Shell 全局处理，与焦点无关）。
  final ValueNotifier<int>? toolbarDismissTick;

  /// Ctrl/Cmd+S 立即保存通知（Shell 全局处理）。
  final ValueNotifier<int>? saveTick;

  /// 同步引擎（null = 未接线，如单测）。
  final BackupManager? backup;

  /// 更新检查（null = 未接线，如单测）。
  final UpdateChecker? updateChecker;

  /// 崩溃日志（null = 未接线，如测试）。
  final CrashJournal? journal;

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  late final q.QuillController _quill;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scroll = ScrollController();
  final Debouncer _saveDebounce = Debouncer(
    const Duration(milliseconds: _autoSaveDebounceMs),
  );
  final Debouncer _journalDebounce = Debouncer(
    const Duration(milliseconds: _journalThrottleMs),
  );

  StreamSubscription<q.DocChange>? _changesSub;
  bool _showToolbar = false;

  /// 上次成功保存的内容（Delta JSON），避免空保存。
  String _lastSavedContent = '';

  /// 崩溃恢复待确认项。
  CrashJournalEntry? _pendingRecover;

  @override
  void initState() {
    super.initState();
    _quill = q.QuillController(
      document: _documentFromCurrent(),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _lastSavedContent = widget.library.currentDocument?.content ?? '';
    _changesSub = _quill.document.changes.listen(_onDocChange);
    _quill.addListener(_onQuillNotify);
    _focusNode.addListener(_onFocusChanged);
    widget.toolbarDismissTick?.addListener(_onDismissToolbar);
    widget.saveTick?.addListener(_onSaveTick);
    // 切换/退出前先保存（防丢）。
    widget.library.beforeSwitchSave = _saveNow;
    _checkRecovery();
  }

  @override
  void didUpdateWidget(covariant EditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library.currentDocument?.id !=
        widget.library.currentDocument?.id) {
      final doc = widget.library.currentDocument;
      if (doc != null) _loadDocument(doc);
    }
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    _quill.dispose();
    _focusNode.dispose();
    _scroll.dispose();
    _saveDebounce.cancel();
    _journalDebounce.cancel();
    widget.toolbarDismissTick?.removeListener(_onDismissToolbar);
    widget.saveTick?.removeListener(_onSaveTick);
    if (widget.library.beforeSwitchSave == _saveNow) {
      widget.library.beforeSwitchSave = null;
    }
    super.dispose();
  }

  /// Esc（Shell 全局）→ 收起工具栏。
  void _onDismissToolbar() {
    if (_showToolbar && mounted) setState(() => _showToolbar = false);
  }

  /// Ctrl/Cmd+S（Shell 全局）→ 立即保存并闪「已保存」。
  void _onSaveTick() {
    _saveNow();
  }

  // ── 文档装载 ──────────────────────────────────────────────

  q.Document _documentFromCurrent() {
    final doc = widget.library.currentDocument;
    if (doc == null) return q.Document();
    return _documentFromJson(doc.content);
  }

  q.Document _documentFromJson(String json) {
    if (json.isEmpty || json == emptyDeltaJson) return q.Document();
    try {
      final ops = parseDeltaOps(json);
      if (ops.isEmpty) return q.Document();
      return q.Document.fromJson(ops);
    } on FormatException {
      return q.Document();
    }
  }

  void _loadDocument(m.Document doc) {
    _changesSub?.cancel();
    _quill.document = _documentFromJson(doc.content);
    _changesSub = _quill.document.changes.listen(_onDocChange);
    _lastSavedContent = doc.content;
    widget.library.reportLiveWords(doc.words);
    _showToolbar = false;
  }

  // ── 变更 → 字数 / 自动保存 / 崩溃日志 ──────────────────────

  void _onDocChange(q.DocChange _) {
    final words = wordCount(_quill.document.toPlainText());
    widget.library.reportLiveWords(words);
    _saveDebounce.schedule(_saveNow);
    _journalDebounce.schedule(_writeJournal);
  }

  void _onQuillNotify() {
    final sel = _quill.selection;
    final hasSelection = sel.isValid && !sel.isCollapsed && sel.baseOffset >= 0;
    if (hasSelection != _showToolbar) {
      setState(() => _showToolbar = hasSelection);
    }
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) {
      _saveDebounce.flush(_saveNow); // 失焦立即保存
    }
  }

  /// 保存当前缓冲：成功清崩溃日志 + 闪「已保存」；失败保留缓冲 + 错误条。
  Future<void> _saveNow() async {
    final cur = widget.library.currentDocument;
    if (cur == null) return;
    final content = jsonEncode(_quill.document.toDelta().toJson());
    if (content == _lastSavedContent) return;
    try {
      await widget.library.saveCurrentDocument(
        title: cur.title,
        content: content,
      );
      _lastSavedContent = content;
      widget.library.savedAt.value = DateTime.now();
      widget.library.clearSaveError();
      await widget.journal?.clear();
    } catch (_) {
      widget.library.reportSaveError('保存失败，请重试');
    }
  }

  /// 崩溃日志：变更节流写入，保存成功后清除。
  Future<void> _writeJournal() async {
    final journal = widget.journal;
    final cur = widget.library.currentDocument;
    if (journal == null || cur == null) return;
    final content = jsonEncode(_quill.document.toDelta().toJson());
    await journal.write(
      CrashJournalEntry(
        documentId: cur.id,
        title: cur.title,
        content: content,
        savedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> _checkRecovery() async {
    final journal = widget.journal;
    final cur = widget.library.currentDocument;
    if (journal == null || cur == null) return;
    final entry = await journal.read();
    if (entry == null) return;
    final content = entry.content;
    // 缓冲与库一致（已保存过）则无需恢复。
    if (entry.documentId == cur.id && content != _lastSavedContent) {
      if (mounted) setState(() => _pendingRecover = entry);
    } else {
      await journal.clear();
    }
  }

  void _restoreRecovery() {
    final entry = _pendingRecover;
    if (entry == null) return;
    _changesSub?.cancel();
    _quill.document = _documentFromJson(entry.content);
    _changesSub = _quill.document.changes.listen(_onDocChange);
    _lastSavedContent = entry.content; // 已是最新缓冲
    setState(() => _pendingRecover = null);
    _saveNow(); // 立即落库
  }

  void _dismissRecovery() {
    setState(() => _pendingRecover = null);
    widget.journal?.clear();
  }

  // ── 构建 ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = widget.settings.settings;
    final colors = Theme.of(context).colorScheme;
    final focusMode = widget.focusMode;
    final meta = isMacOS;
    return Shortcuts(
      shortcuts: {
        // Ctrl/Cmd+S 立即保存（ui-editor.md Interactions）。
        SingleActivator(LogicalKeyboardKey.keyS, meta: meta, control: !meta):
            _SaveIntent(),
      },
      child: Actions(
        actions: {
          _SaveIntent: CallbackAction(
            onInvoke: (_) {
              _saveNow();
              return true;
            },
          ),
        },
        child: Column(
          children: [
            if (widget.library.pendingDeletion != null)
              _DeleteBar(
                request: widget.library.pendingDeletion!,
                onCancel: widget.library.cancelDelete,
                onConfirm: widget.library.confirmDelete,
              ),
            if (!focusMode)
              _EditorHeader(
                title: widget.library.currentDocument?.title ?? '',
                focusMode: focusMode,
                onToggleFocusMode: widget.onToggleFocusMode,
                onOpenSettings: () => _openSettings(),
              ),
            if (_pendingRecover != null)
              _RecoveryBar(
                entry: _pendingRecover!,
                onRestore: _restoreRecovery,
                onDismiss: _dismissRecovery,
              ),
            Expanded(
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: FocusView(
                  focusMode: focusMode,
                  onExit: widget.onToggleFocusMode,
                  liveWords:
                      widget.library.liveDocWords ??
                      widget.library.currentDocument?.words ??
                      0,
                  todayDelta: widget.library.todayDelta,
                  dailyGoal: s.dailyGoal,
                  child: _buildEditorArea(s, colors),
                ),
              ),
            ),
            if (!focusMode)
              StatusBar(
                library: widget.library,
                settings: widget.settings,
                onRetrySave: _saveNow,
                backup: widget.backup,
                onOpenSettings:
                    ({bool focusDailyGoal = false, bool focusSync = false}) =>
                        _openSettings(
                          focusDailyGoal: focusDailyGoal,
                          focusSync: focusSync,
                        ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditorArea(m.Settings s, ColorScheme colors) {
    // 空文档：Quill 占位 + 垂直居中的引导语（不再"悬在左上角"）。
    final doc = widget.library.currentDocument;
    final empty =
        doc == null || doc.content.isEmpty || doc.content == emptyDeltaJson;
    return Stack(
      children: [
        Positioned.fill(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: q.QuillEditor(
                controller: _quill,
                focusNode: _focusNode,
                scrollController: _scroll,
                config: q.QuillEditorConfig(
                  placeholder: empty ? '' : '从这里开始写…',
                  autoFocus: false,
                  expands: true,
                  scrollable: true,
                  padding: const EdgeInsets.symmetric(
                    vertical: _contentVPadding,
                    horizontal: 24,
                  ),
                  customStyles: _buildStyles(s),
                ),
              ),
            ),
          ),
        ),
        if (empty)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Text(
                  '从这里开始写…',
                  style: TextStyle(
                    fontSize: 16,
                    fontStyle: FontStyle.italic,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        if (_showToolbar && !widget.focusMode)
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(child: _FloatingToolbar(quill: _quill)),
          ),
      ],
    );
  }

  /// 编辑器样式：设置字号/行距/字体 + 标题阶梯（style.md §4）。
  q.DefaultStyles _buildStyles(m.Settings s) {
    final base = TextStyle(
      fontSize: s.fontSize,
      height: s.lineHeight,
      color: Theme.of(context).colorScheme.onSurface,
      letterSpacing: -0.12,
      fontFamily: s.fontFamily.isEmpty ? null : s.fontFamily,
      decoration: TextDecoration.none,
    );
    TextStyle header(double size) => base.copyWith(
      fontSize: size,
      height: 1.25,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.45,
    );
    q.DefaultTextBlockStyle block(TextStyle style) => q.DefaultTextBlockStyle(
      style,
      const q.HorizontalSpacing(0, 0),
      const q.VerticalSpacing(4, 2),
      const q.VerticalSpacing(0, 0),
      BoxDecoration(),
    );
    return q.DefaultStyles(
      paragraph: block(base),
      h1: block(header(30)),
      h2: block(header(24)),
      h3: block(header(20)),
    );
  }

  /// 打开设置：桌面模态对话框（480px）/ Android 全屏页（ui-settings.md）。
  void _openSettings({bool focusDailyGoal = false, bool focusSync = false}) {
    final view = SettingsView(
      settings: widget.settings,
      library: widget.library,
      backup: widget.backup,
      updateChecker: widget.updateChecker,
      dbSchemaVersion: widget.updateChecker?.dbSchemaVersion,
      autoFocusDailyGoal: focusDailyGoal,
      autoFocusSync: focusSync,
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
            Dialog(child: SizedBox(width: 480, height: 520, child: view)),
      );
    }
  }
}

/// 保存意图（Ctrl/Cmd+S）。
class _SaveIntent extends Intent {
  const _SaveIntent();
}

/// 顶栏：轻量 breadcrumb + 页面操作。
class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.title,
    required this.focusMode,
    required this.onToggleFocusMode,
    required this.onOpenSettings,
  });

  final String title;
  final bool focusMode;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final displayTitle = title.isEmpty ? '未选择文档' : title;
    return GlassSurface(
      color: Theme.of(context).scaffoldBackgroundColor,
      border: Border(bottom: BorderSide(color: colors.outline)),
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            const SizedBox(width: 18),
            Icon(
              Icons.description_outlined,
              size: 16,
              color: appColors.textTertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: title.isEmpty
                      ? appColors.textTertiary
                      : colors.onSurfaceVariant,
                ),
              ),
            ),
            _HeaderAction(
              onPressed: onToggleFocusMode,
              tooltip: '沉浸模式 (${isMacOS ? '⌘' : 'Ctrl'}+Shift+F)',
              icon: Icons.open_in_full,
              label: '专注',
            ),
            const SizedBox(width: 4),
            _HeaderAction(
              onPressed: onOpenSettings,
              tooltip: '设置',
              icon: Icons.tune,
              label: '偏好',
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

class _HeaderAction extends StatefulWidget {
  const _HeaderAction({
    required this.onPressed,
    required this.tooltip,
    required this.icon,
    required this.label,
  });

  final VoidCallback onPressed;
  final String tooltip;
  final IconData icon;
  final String label;

  @override
  State<_HeaderAction> createState() => _HeaderActionState();
}

class _HeaderActionState extends State<_HeaderAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: _hover ? appColors.surfaceHover : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              children: [
                Icon(widget.icon, size: 15, color: colors.onSurfaceVariant),
                const SizedBox(width: 5),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 上下文工具栏：选中文本时浮现（Notion-like compact floating bar）。
class _FloatingToolbar extends StatelessWidget {
  const _FloatingToolbar({required this.quill});

  final q.QuillController quill;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final active = quill.getSelectionStyle().attributes;

    bool isActive(String key, [Object? value]) {
      final attr = active[key];
      if (attr == null) return false;
      return value == null || attr.value == value;
    }

    Widget btn({
      required Widget icon,
      required String tooltip,
      required bool isActive,
      required VoidCallback onTap,
    }) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isActive ? appColors.rowSelected : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: IconTheme(
              data: IconThemeData(
                size: 17,
                color: isActive ? colors.onSurface : colors.onSurfaceVariant,
              ),
              child: icon,
            ),
          ),
        ),
      );
    }

    Widget textBtn(
      String label,
      String tooltip,
      bool active,
      VoidCallback onTap,
    ) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? appColors.rowSelected : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? colors.onSurface : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return GlassSurface(
      radius: 7,
      shadow: true,
      color: appColors.surfaceRaised,
      border: Border.all(color: colors.outline),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          textBtn(
            'H1',
            '标题 1',
            isActive('header', 1),
            () => quill.formatSelection(q.Attribute.h1),
          ),
          textBtn(
            'H2',
            '标题 2',
            isActive('header', 2),
            () => quill.formatSelection(q.Attribute.h2),
          ),
          textBtn(
            'H3',
            '标题 3',
            isActive('header', 3),
            () => quill.formatSelection(q.Attribute.h3),
          ),
          _sep(colors),
          btn(
            icon: const Icon(Icons.format_bold),
            tooltip: '加粗',
            isActive: isActive('bold'),
            onTap: () => quill.formatSelection(q.Attribute.bold),
          ),
          btn(
            icon: const Icon(Icons.format_italic),
            tooltip: '斜体',
            isActive: isActive('italic'),
            onTap: () => quill.formatSelection(q.Attribute.italic),
          ),
          btn(
            icon: const Icon(Icons.format_underline),
            tooltip: '下划线',
            isActive: isActive('underline'),
            onTap: () => quill.formatSelection(q.Attribute.underline),
          ),
          btn(
            icon: const Icon(Icons.format_strikethrough),
            tooltip: '删除线',
            isActive: isActive('strike'),
            onTap: () => quill.formatSelection(q.Attribute.strikeThrough),
          ),
          _sep(colors),
          btn(
            icon: const Icon(Icons.format_list_bulleted),
            tooltip: '无序列表',
            isActive: isActive('list', 'bullet'),
            onTap: () => quill.formatSelection(q.Attribute.ul),
          ),
          btn(
            icon: const Icon(Icons.format_list_numbered),
            tooltip: '有序列表',
            isActive: isActive('list', 'ordered'),
            onTap: () => quill.formatSelection(q.Attribute.ol),
          ),
          _sep(colors),
          btn(
            icon: const Icon(Icons.format_quote),
            tooltip: '引用',
            isActive: isActive('blockquote'),
            onTap: () => quill.formatSelection(q.Attribute.blockQuote),
          ),
          btn(
            icon: const Icon(Icons.code),
            tooltip: '行内代码',
            isActive: isActive('code'),
            onTap: () => quill.formatSelection(q.Attribute.inlineCode),
          ),
          btn(
            icon: const Icon(Icons.data_object),
            tooltip: '代码块',
            isActive: isActive('code-block'),
            onTap: () => quill.formatSelection(q.Attribute.codeBlock),
          ),
        ],
      ),
    );
  }

  Widget _sep(ColorScheme colors) => Container(
    width: 1,
    height: 18,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: colors.outline,
  );
}

/// 崩溃恢复确认条（启动时缓冲与库不一致）。
class _RecoveryBar extends StatelessWidget {
  const _RecoveryBar({
    required this.entry,
    required this.onRestore,
    required this.onDismiss,
  });

  final CrashJournalEntry entry;
  final VoidCallback onRestore;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return _NoticeBar(
      icon: Icons.restore,
      text: '检测到《${entry.title}》的未保存内容，恢复？',
      tone: _NoticeTone.warning,
      actions: [
        _NoticeAction(label: '忽略', onTap: onDismiss),
        _NoticeAction(label: '恢复', onTap: onRestore, emphasized: true),
      ],
    );
  }
}

/// 删除确认条：编辑器区顶部轻量 callout，5s 无操作自动关。
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
    return _NoticeBar(
      icon: Icons.warning_amber_outlined,
      text: '删除《${widget.request.name}》？此操作不可恢复',
      tone: _NoticeTone.danger,
      actions: [
        _NoticeAction(label: '取消', onTap: widget.onCancel),
        _NoticeAction(
          label: '确认删除',
          onTap: () => widget.onConfirm(),
          emphasized: true,
        ),
      ],
    );
  }
}

enum _NoticeTone { warning, danger }

class _NoticeAction {
  const _NoticeAction({
    required this.label,
    required this.onTap,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool emphasized;
}

class _NoticeBar extends StatelessWidget {
  const _NoticeBar({
    required this.icon,
    required this.text,
    required this.tone,
    required this.actions,
  });

  final IconData icon;
  final String text;
  final _NoticeTone tone;
  final List<_NoticeAction> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final toneColor = tone == _NoticeTone.danger
        ? colors.error
        : colors.primary;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: appColors.callout,
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: toneColor),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: colors.onSurface),
            ),
          ),
          for (final action in actions) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: action.onTap,
              style: TextButton.styleFrom(
                foregroundColor: action.emphasized
                    ? toneColor
                    : colors.onSurfaceVariant,
                backgroundColor: action.emphasized
                    ? toneColor.withValues(alpha: 0.10)
                    : null,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
              ),
              child: Text(action.label),
            ),
          ],
        ],
      ),
    );
  }
}
