/// 所见即所得编辑器：Quill 编辑器 + 页面大标题 + 斜杠命令菜单 +
/// Markdown 快捷语法 + 上下文工具栏 + 自动保存 + 字数。
///
/// 设计依据：docs/app/ui-editor.md（Region Layout / Interactions /
/// Word Count / State Variants）、docs/app/style.md（§3 tokens、§4 字体、
/// §5 尺寸、§9 组件样式）、docs/app/README.md §7（自动保存优先、无模态打断）。
/// 视觉方向：Notion-inspired —— 页面即纸张、块级排版、低打扰 chrome。
library;

// flutter_quill 的输入快捷事件 API 标注 @experimental（11.x 起稳定提供，
// AppFlowy 同源实现）；markdown 快捷语法依赖它，按版本锁定使用。
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'slash_menu.dart';
import 'status_bar.dart';

const int _autoSaveDebounceMs = 1000;
const int _journalThrottleMs = 500;
const double _maxContentWidth = 760;

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
  final GlobalKey<q.EditorState> _editorKey = GlobalKey<q.EditorState>();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scroll = ScrollController();
  final Debouncer _saveDebounce = Debouncer(
    const Duration(milliseconds: _autoSaveDebounceMs),
  );
  final Debouncer _journalDebounce = Debouncer(
    const Duration(milliseconds: _journalThrottleMs),
  );

  StreamSubscription<q.DocChange>? _changesSub;

  /// 上次成功保存的内容（Delta JSON），避免空保存。
  String _lastSavedContent = '';

  /// 崩溃恢复待确认项。
  CrashJournalEntry? _pendingRecover;

  // ── 斜杠命令菜单状态（overlay 承载，锚定光标）─────────────
  OverlayEntry? _slashOverlay;
  int _slashAnchor = -1;
  List<SlashCommand> _slashMatches = kSlashCommands;
  int _slashIndex = 0;
  Offset _slashPosition = Offset.zero;
  bool _slashKeyHandlerAdded = false;

  @override
  void initState() {
    super.initState();
    _quill = q.QuillController(
      document: _documentFromCurrent(),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _lastSavedContent = widget.library.currentDocument?.content ?? '';
    _changesSub = _quill.document.changes.listen(_onDocChange);
    _quill.addListener(_onQuillChanged);
    _scroll.addListener(_onEditorScrolled);
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
    _closeSlash();
    _changesSub?.cancel();
    _quill.removeListener(_onQuillChanged);
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

  /// Esc（Shell 全局）→ 收起 Quill 的选区菜单并折叠选区。
  void _onDismissToolbar() {
    final selection = _quill.selection;
    if (selection.isValid && !selection.isCollapsed) {
      _quill.updateSelection(
        TextSelection.collapsed(offset: selection.extentOffset),
        q.ChangeSource.local,
      );
    }
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
    _closeSlash();
    _changesSub?.cancel();
    _quill.document = _documentFromJson(doc.content);
    _changesSub = _quill.document.changes.listen(_onDocChange);
    _lastSavedContent = doc.content;
    widget.library.reportLiveWords(doc.words);
  }

  // ── 变更 → 字数 / 自动保存 / 崩溃日志 / 斜杠菜单 ────────────

  void _onDocChange(q.DocChange change) {
    final words = wordCount(_quill.document.toPlainText());
    widget.library.reportLiveWords(words);
    _saveDebounce.schedule(_saveNow);
    _journalDebounce.schedule(_writeJournal);
    _handleSlashTrigger(change);
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

  // ── Markdown 快捷语法（行首触发词 + 空格 → 块格式）──────────

  /// 触发词整行匹配时：删除触发词并格式化当前行。
  ///
  /// 不用 flutter_quill 内置 handler 的「插入 \n 占位再删除」技巧——
  /// 该技巧在文档末尾会被 EnsureLastLineBreak 删除规则拦截，
  /// 留下一个多余空行。
  static bool _formatLinePrefix(
    q.QuillController controller,
    q.QuillText node,
    String phrase,
    q.Attribute attribute,
  ) {
    final lineStart = node.documentOffset;
    // 仅当光标恰好位于触发词之后（行首输入场景）才转换。
    if (controller.selection.baseOffset != lineStart + phrase.length) {
      return false;
    }
    controller
      ..replaceText(
        lineStart,
        phrase.length,
        '',
        TextSelection.collapsed(offset: lineStart),
      )
      ..formatSelection(attribute);
    return true;
  }

  /// 行首「触发词 + 空格」→ 块格式（Notion/markdown 惯例）。
  static final List<q.SpaceShortcutEvent> _spaceShortcuts = [
    for (final (phrase, attr) in <(String, q.Attribute)>[
      ('#', q.Attribute.h1),
      ('##', q.Attribute.h2),
      ('###', q.Attribute.h3),
      ('-', q.Attribute.ul),
      ('*', q.Attribute.ul),
      ('1.', q.Attribute.ol),
      ('>', q.Attribute.blockQuote),
      ('[]', q.Attribute.unchecked),
      ('[x]', q.Attribute.checked),
      ('```', q.Attribute.codeBlock),
    ])
      q.SpaceShortcutEvent(
        character: phrase,
        handler: (node, controller) =>
            _formatLinePrefix(controller, node, phrase, attr),
      ),
  ];

  // ── 斜杠命令菜单 ──────────────────────────────────────────

  /// 单次插入的纯文本（多段插入/删除返回 null）。
  String? _insertedText(q.DocChange change) {
    String? inserted;
    for (final op in change.change.toList()) {
      if (op.isInsert) {
        if (inserted != null) return null;
        final data = op.data;
        if (data is! String) return null;
        inserted = data;
      } else if (op.isDelete) {
        return null;
      }
    }
    return inserted;
  }

  void _handleSlashTrigger(q.DocChange change) {
    if (_slashOverlay != null) {
      _refreshSlash();
      return;
    }
    if (change.source != q.ChangeSource.local) return;
    if (_insertedText(change) != '/') return;
    final sel = _quill.selection;
    if (!sel.isValid || !sel.isCollapsed) return;
    _slashAnchor = sel.baseOffset - 1;
    if (_slashAnchor < 0) return;
    _slashMatches = kSlashCommands;
    _slashIndex = 0;
    _openSlashOverlay();
  }

  /// 控制器任何通知（选区/文档）时校验菜单有效性并刷新过滤。
  void _onQuillChanged() {
    if (_slashOverlay != null) _refreshSlash();
  }

  void _onEditorScrolled() {
    if (_slashOverlay != null) _positionSlash();
  }

  void _refreshSlash() {
    final sel = _quill.selection;
    if (!sel.isValid || !sel.isCollapsed) return _closeSlash();
    final caret = sel.baseOffset;
    final plain = _quill.document.toPlainText();
    if (_slashAnchor < 0 ||
        _slashAnchor >= plain.length ||
        plain[_slashAnchor] != '/' ||
        caret <= _slashAnchor) {
      return _closeSlash();
    }
    final query = plain.substring(_slashAnchor + 1, math.min(caret, plain.length));
    if (query.contains('\n') || query.length > 16) return _closeSlash();
    final matches = filterSlashCommands(query);
    if (matches.isEmpty) return _closeSlash();
    _slashMatches = matches;
    if (_slashIndex >= matches.length) _slashIndex = 0;
    _slashOverlay?.markNeedsBuild();
    _positionSlash();
  }

  void _openSlashOverlay() {
    _slashOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // 透明监听层：点击任意处关闭菜单，且不拦截下层交互。
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _closeSlash(),
            ),
          ),
          Positioned(
            left: _slashPosition.dx,
            top: _slashPosition.dy,
            child: SlashMenuPanel(
              commands: _slashMatches,
              selectedIndex: _slashIndex,
              onSelect: _applySlash,
              onHover: (i) {
                if (_slashIndex == i) return;
                _slashIndex = i;
                _slashOverlay?.markNeedsBuild();
              },
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_slashOverlay!);
    HardwareKeyboard.instance.addHandler(_onSlashKey);
    _slashKeyHandlerAdded = true;
    _positionSlash();
  }

  /// 菜单锚定光标下缘；触底翻转到上缘（Notion 行为）。
  void _positionSlash() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _slashOverlay == null) return;
      final editorState = _editorKey.currentState;
      if (editorState == null) return;
      final render = editorState.renderEditor;
      if (!render.attached) return;
      final caret = render.getLocalRectForCaret(
        TextPosition(offset: _slashAnchor),
      );
      final bottomLeft = render.localToGlobal(caret.bottomLeft);
      final topLeft = render.localToGlobal(caret.topLeft);
      final screen = MediaQuery.sizeOf(context);
      final menuHeight = math.min(
        SlashMenuPanel.maxHeight,
        _slashMatches.length * SlashMenuPanel.itemHeight + 34,
      );
      var pos = Offset(bottomLeft.dx, bottomLeft.dy + 6);
      if (pos.dy + menuHeight > screen.height - 12) {
        pos = Offset(topLeft.dx, topLeft.dy - menuHeight - 6);
      }
      pos = Offset(
        pos.dx.clamp(8.0, math.max(8.0, screen.width - SlashMenuPanel.width - 8)),
        math.max(8.0, pos.dy),
      );
      if ((pos - _slashPosition).distance > 0.5) {
        _slashPosition = pos;
        _slashOverlay?.markNeedsBuild();
      }
    });
  }

  /// 菜单开启时接管 ↑↓/Enter/Esc（先于编辑器焦点系统分发）。
  bool _onSlashKey(KeyEvent event) {
    if (_slashOverlay == null || event is KeyUpEvent) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _slashIndex = (_slashIndex + 1) % _slashMatches.length;
      _slashOverlay!.markNeedsBuild();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _slashIndex =
          (_slashIndex - 1 + _slashMatches.length) % _slashMatches.length;
      _slashOverlay!.markNeedsBuild();
      return true;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      _applySlash(_slashMatches[_slashIndex]);
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      _closeSlash();
      return true;
    }
    return false;
  }

  void _applySlash(SlashCommand cmd) {
    final anchor = _slashAnchor;
    final caret = _quill.selection.baseOffset;
    _closeSlash();
    if (anchor < 0) return;
    // 删除「/query」触发文本，再对所在行应用块格式。
    final end = math.max(caret, anchor + 1);
    _quill.replaceText(
      anchor,
      end - anchor,
      '',
      TextSelection.collapsed(offset: anchor),
    );
    switch (cmd.id) {
      case 'text':
        for (final attr in <q.Attribute<dynamic>>[
          q.Attribute.header,
          q.Attribute.list,
          q.Attribute.blockQuote,
          q.Attribute.codeBlock,
        ]) {
          _quill.formatSelection(q.Attribute.clone(attr, null));
        }
      case 'h1':
        _quill.formatSelection(q.Attribute.h1);
      case 'h2':
        _quill.formatSelection(q.Attribute.h2);
      case 'h3':
        _quill.formatSelection(q.Attribute.h3);
      case 'bullet':
        _quill.formatSelection(q.Attribute.ul);
      case 'ordered':
        _quill.formatSelection(q.Attribute.ol);
      case 'todo':
        _quill.formatSelection(q.Attribute.unchecked);
      case 'quote':
        _quill.formatSelection(q.Attribute.blockQuote);
      case 'code':
        _quill.formatSelection(q.Attribute.codeBlock);
    }
    _focusNode.requestFocus();
  }

  void _closeSlash() {
    if (_slashKeyHandlerAdded) {
      HardwareKeyboard.instance.removeHandler(_onSlashKey);
      _slashKeyHandlerAdded = false;
    }
    final entry = _slashOverlay;
    _slashOverlay = null;
    _slashAnchor = -1;
    if (entry != null) {
      entry
        ..remove()
        ..dispose();
    }
  }

  // ── 链接 ──────────────────────────────────────────────────

  static String _normalizeUrl(String url) =>
      url.contains('://') || url.startsWith('mailto:') ? url : 'https://$url';

  Future<void> _promptLink() async {
    final current =
        _quill.getSelectionStyle().attributes['link']?.value as String? ?? '';
    final input = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('链接'),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: input,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'https://…'),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
        ),
        actions: [
          if (current.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(''),
              child: const Text('移除链接'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(input.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (result != null) {
      if (result.isEmpty) {
        _quill.formatSelection(q.Attribute.clone(q.Attribute.link, null));
      } else {
        _quill.formatSelection(q.LinkAttribute(_normalizeUrl(result)));
      }
    }
    input.dispose();
  }

  // ── 构建 ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = widget.settings.settings;
    final colors = Theme.of(context).colorScheme;
    final focusMode = widget.focusMode;
    final meta = isMacOS;
    final doc = widget.library.currentDocument;
    final notebookName = doc == null
        ? null
        : widget.library.notebooks
              .where((nb) => nb.id == doc.notebookId)
              .map((nb) => nb.name)
              .firstOrNull;
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
                title: doc?.title ?? '',
                notebookName: notebookName,
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
                  liveWords: widget.library.liveWords,
                  fallbackWords: doc?.words ?? 0,
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
                    ({bool focusDailyGoal = false, bool focusBackup = false}) =>
                        _openSettings(
                          focusDailyGoal: focusDailyGoal,
                          focusBackup: focusBackup,
                        ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditorArea(m.Settings s, ColorScheme colors) {
    final doc = widget.library.currentDocument;
    final hasDoc = doc != null;
    final focusMode = widget.focusMode;
    final editor = q.QuillEditor(
      controller: _quill,
      focusNode: _focusNode,
      scrollController: _scroll,
      config: q.QuillEditorConfig(
        editorKey: _editorKey,
        placeholder: hasDoc ? '输入 / 唤起命令，或直接开始写…' : null,
        autoFocus: false,
        expands: true,
        scrollable: true,
        padding: EdgeInsets.fromLTRB(
          24,
          focusMode ? 88 : 8,
          24,
          focusMode ? 88 : 160,
        ),
        customStyles: _buildStyles(s),
        characterShortcutEvents: q.standardCharactersShortcutEvents,
        spaceShortcutEvents: _spaceShortcuts,
        // 桌面点击菜单/侧栏不丢编辑焦点（Notion 行为）；移动端收起键盘。
        onTapOutside: (event, focusNode) {
          if (!isDesktopPlatform) focusNode.unfocus();
        },
        // Quill 负责选区锚点和安全区域翻转：桌面贴近鼠标完成选取的
        // 位置，移动端贴近实际选段，避免工具栏固定在页面顶部。
        enableSelectionToolbar: !focusMode,
        contextMenuBuilder: focusMode
            ? null
            : (context, rawEditorState) => _SelectionToolbarMenu(
                anchors: rawEditorState.contextMenuAnchors,
                buttonItems: rawEditorState.contextMenuButtonItems,
                child: _FloatingToolbar(quill: _quill, onLink: _promptLink),
              ),
      ),
    );
    return Column(
      children: [
        // Notion 式页面大标题：编辑即重命名，Enter 落入正文。
        if (hasDoc && !focusMode)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 34, 24, 0),
                child: _PageTitle(
                  docId: doc.id,
                  title: doc.title,
                  onRename: (name) async {
                    try {
                      await widget.library.renameDocument(doc.id, name);
                    } catch (_) {
                      // 改名失败不打断书写；标题下次同步回库内值。
                    }
                  },
                  onNext: () {
                    _quill.updateSelection(
                      const TextSelection.collapsed(offset: 0),
                      q.ChangeSource.local,
                    );
                    _focusNode.requestFocus();
                  },
                ),
              ),
            ),
          ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: _maxContentWidth,
                    ),
                    child: editor,
                  ),
                ),
              ),
              // 未选择文档：编辑器保持挂载（占位空态），上面盖引导提示。
              if (!hasDoc)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: _NoDocumentHint(colors: colors),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 编辑器样式：设置字号/行距/字体 + Notion 式块排版
  /// （标题阶梯留白、引用竖线、代码块底色、行内代码红字）。
  q.DefaultStyles _buildStyles(m.Settings s) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final base = TextStyle(
      fontSize: s.fontSize,
      height: s.lineHeight,
      color: colors.onSurface,
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
    final mono = base.copyWith(
      fontSize: s.fontSize - 1.5,
      height: 1.55,
      letterSpacing: 0,
      fontFamily: 'Menlo',
      fontFamilyFallback: const ['Consolas', 'monospace'],
    );
    q.DefaultTextBlockStyle block(
      TextStyle style, {
      q.VerticalSpacing spacing = const q.VerticalSpacing(3, 3),
    }) => q.DefaultTextBlockStyle(
      style,
      const q.HorizontalSpacing(0, 0),
      spacing,
      const q.VerticalSpacing(0, 0),
      const BoxDecoration(),
    );
    return q.DefaultStyles(
      paragraph: block(base),
      placeHolder: block(base.copyWith(color: appColors.textTertiary)),
      h1: block(header(30), spacing: const q.VerticalSpacing(24, 6)),
      h2: block(header(24), spacing: const q.VerticalSpacing(18, 5)),
      h3: block(header(20), spacing: const q.VerticalSpacing(14, 4)),
      lists: q.DefaultListBlockStyle(
        base,
        const q.HorizontalSpacing(0, 0),
        const q.VerticalSpacing(3, 3),
        const q.VerticalSpacing(0, 0),
        null,
        null,
      ),
      quote: q.DefaultTextBlockStyle(
        base,
        const q.HorizontalSpacing(14, 0),
        const q.VerticalSpacing(6, 6),
        const q.VerticalSpacing(0, 0),
        BoxDecoration(
          border: Border(
            left: BorderSide(
              color: colors.onSurface.withValues(alpha: 0.8),
              width: 3,
            ),
          ),
        ),
      ),
      code: q.DefaultTextBlockStyle(
        mono,
        const q.HorizontalSpacing(0, 0),
        const q.VerticalSpacing(8, 8),
        const q.VerticalSpacing(0, 0),
        BoxDecoration(
          color: appColors.callout,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: colors.outline),
        ),
      ),
      inlineCode: q.InlineCodeStyle(
        style: mono.copyWith(
          fontSize: s.fontSize - 2,
          color: const Color(0xFFEB5757),
        ),
        backgroundColor: appColors.callout,
        radius: const Radius.circular(4),
      ),
    );
  }

  /// 打开设置：桌面双栏模态对话框 / Android 全屏页（ui-settings.md）。
  void _openSettings({bool focusDailyGoal = false, bool focusBackup = false}) {
    final view = SettingsView(
      settings: widget.settings,
      library: widget.library,
      backup: widget.backup,
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
}

/// 保存意图（Ctrl/Cmd+S）。
class _SaveIntent extends Intent {
  const _SaveIntent();
}

/// Notion 式页面大标题：TextField 即改名入口，600ms 防抖入库。
class _PageTitle extends StatefulWidget {
  const _PageTitle({
    required this.docId,
    required this.title,
    required this.onRename,
    required this.onNext,
  });

  final String docId;
  final String title;
  final Future<void> Function(String name) onRename;

  /// Enter → 聚焦正文首行。
  final VoidCallback onNext;

  @override
  State<_PageTitle> createState() => _PageTitleState();
}

class _PageTitleState extends State<_PageTitle> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.title,
  );
  final FocusNode _focus = FocusNode();
  final Debouncer _renameDebounce = Debouncer(
    const Duration(milliseconds: 600),
  );

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _renameDebounce.flush(_commit);
    });
  }

  @override
  void didUpdateWidget(covariant _PageTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.docId != widget.docId) {
      _renameDebounce.cancel();
      _controller.text = widget.title;
    } else if (oldWidget.title != widget.title &&
        !_focus.hasFocus &&
        _controller.text != widget.title) {
      // 侧栏重命名等外部变更；输入中（有焦点）不回写，避免打断。
      _controller.text = widget.title;
    }
  }

  @override
  void dispose() {
    _renameDebounce.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final name = _controller.text.trim();
    if (name.isEmpty || name == widget.title) return;
    widget.onRename(name);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return TextField(
      controller: _controller,
      focusNode: _focus,
      maxLines: 1,
      style: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        height: 1.25,
        color: colors.onSurface,
      ),
      cursorColor: colors.onSurface,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText: '无标题',
        hintStyle: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.6,
          color: appColors.textTertiary,
        ),
      ),
      textInputAction: TextInputAction.done,
      onChanged: (_) => _renameDebounce.schedule(_commit),
      onSubmitted: (_) {
        _renameDebounce.flush(_commit);
        widget.onNext();
      },
    );
  }
}

/// 未选择文档的引导空态（编辑器区中央）。
class _NoDocumentHint extends StatelessWidget {
  const _NoDocumentHint({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final appColors = appColorsOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_note, size: 44, color: appColors.textTertiary),
          const SizedBox(height: 10),
          Text(
            '在左侧选择或新建一篇文档，开始写作',
            style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 顶栏：轻量 breadcrumb（笔记本 / 文档）+ 页面操作。
class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.title,
    required this.notebookName,
    required this.onToggleFocusMode,
    required this.onOpenSettings,
  });

  final String title;
  final String? notebookName;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final crumb = title.isEmpty
        ? '未选择文档'
        : notebookName == null
        ? title
        : '$notebookName / $title';
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
                crumb,
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

/// 由 Flutter/Quill 的选区 Overlay 承载，自动锚定选区上方并在边界翻转。
/// 桌面端锚在鼠标完成选取的位置；触摸端锚在实际选段附近。
class _SelectionToolbarMenu extends StatelessWidget {
  const _SelectionToolbarMenu({
    required this.anchors,
    required this.buttonItems,
    required this.child,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AdaptiveTextSelectionToolbar(
      anchors: anchors,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width - 24,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                child,
                if (buttonItems.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  ...AdaptiveTextSelectionToolbar.getAdaptiveButtons(
                    context,
                    buttonItems,
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 上下文工具栏：选中文本时浮现（Notion-like compact floating bar）。
class _FloatingToolbar extends StatelessWidget {
  const _FloatingToolbar({required this.quill, required this.onLink});

  final q.QuillController quill;
  final VoidCallback onLink;

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
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
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
            btn(
              icon: const Icon(Icons.link),
              tooltip: '链接',
              isActive: isActive('link'),
              onTap: onLink,
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
            btn(
              icon: const Icon(Icons.check_box_outlined),
              tooltip: '待办清单',
              isActive:
                  isActive('list', 'unchecked') || isActive('list', 'checked'),
              onTap: () => quill.formatSelection(q.Attribute.unchecked),
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
