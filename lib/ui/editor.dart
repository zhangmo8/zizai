/// 所见即所得编辑器：可编辑顶栏标题 + 斜杠命令菜单 +
/// Markdown 快捷语法 + 常驻格式工具栏 + 选区浮动工具栏 + 自动保存 + 字数。
///
/// 设计依据：docs/app/ui-editor.md（Region Layout / Interactions /
/// Word Count / State Variants）、design.md（Notion token / 光标 /
/// icon 优先）、docs/app/README.md §7（自动保存优先、无模态打断）。
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
import '../core/app_logger.dart';
import '../core/backup/backup.dart';
import '../core/crash_journal.dart';
import '../core/export.dart' show emptyDeltaJson, parseDeltaOps;
import '../core/find.dart';
import '../core/models.dart' as m;
import '../core/outline.dart';
import '../core/snapshot_history.dart';
import '../core/word_count.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import '../util/debounce.dart';
import '../util/ime_state.dart';
import '../util/platform.dart';
import 'find_bar.dart';
import 'focus_view.dart';
import 'glass.dart';
import 'notes_panel.dart';
import 'outline_panel.dart';
import 'slash_menu.dart';
import 'snapshot_panel.dart';
import 'status_bar.dart';
import 'zz.dart';

const int _autoSaveDebounceMs = 1000;
const int _journalThrottleMs = 500;
const int _outlineDebounceMs = 300;
const double _maxContentWidth = 760;

// ── 标点自动配对 ──────────────────────────────────────────────

/// 开括号 → 对应闭括号。输入开括号时自动补全闭括号，光标停在中间。
const Map<String, String> _bracketPairs = {
  '(': ')',
  '（': '）',
  '【': '】',
  '“': '”',
  '"': '"',
  '「': '」',
  '{': '}',
};

/// 闭括号集合：补全对中间输入时跳过（避免重复），`"` 开闭同字符。
const Set<String> _bracketClosing = {'）', '】', '”', '"', '」', '}'};

final Set<String> _bracketChars = {..._bracketPairs.keys, ..._bracketClosing};

/// 标点配对修正（纯函数，便于单测）：把 [typed] 插入 [before] 的 [pos] 处后
/// 应得到的 (文本, 光标位置)；无需修正返回 null。
///
/// - 光标紧邻同名闭括号（补全对中间）→ 跳过：文本不变，光标右移 1
/// - 输入开括号 → 补全对应闭括号，光标停在中间（[pos] + 1）
///
/// [pos] 为插入前光标位置（0..before.length）；仅处理 [_bracketChars] 字符。
(String, int)? bracketPairCorrection(String before, int pos, String typed) {
  if (pos < 0 || pos > before.length) return null;
  if (_bracketClosing.contains(typed) &&
      pos < before.length &&
      before[pos] == typed) {
    return (before, pos + 1);
  }
  final close = _bracketPairs[typed];
  if (close == null) return null;
  return (
    before.substring(0, pos) + typed + close + before.substring(pos),
    pos + 1,
  );
}

/// 窄窗强制收起大纲常驻面板的窗口宽度阈值（ui-editor.md §大纲面板）。
const double _outlineMinWindowWidth = 960;

/// 全书搜索点击命中后的跳转请求（Shell 下发；编辑器装载目标文档后消费）。
class EditorJumpRequest {
  const EditorJumpRequest({
    required this.documentId,
    required this.offset,
    required this.length,
  });

  final String documentId;
  final int offset;
  final int length;
}

class EditorView extends StatefulWidget {
  const EditorView({
    super.key,
    required this.library,
    required this.settings,
    required this.focusMode,
    required this.onToggleFocusMode,
    required this.onOpenSettings,
    this.backup,
    this.toolbarDismissTick,
    this.saveTick,
    this.findTick,
    this.journal,
    this.logger,
    this.snapshots,
    this.jumpRequest,
    this.sidebarVisible = false,
    this.onToggleSidebar,
  });

  final LibraryController library;
  final SettingsController settings;
  final bool focusMode;
  final VoidCallback onToggleFocusMode;
  final void Function({bool focusDailyGoal, bool focusBackup}) onOpenSettings;

  /// 侧边栏当前可见（桌面端按钮 active 态；Android Drawer 形态忽略）。
  final bool sidebarVisible;

  /// 切换侧边栏：桌面 = 显隐切换；Android = 打开 Drawer。null = 不显示按钮。
  final VoidCallback? onToggleSidebar;

  /// Esc 收起工具栏通知（Shell 全局处理，与焦点无关）。
  final ValueNotifier<int>? toolbarDismissTick;

  /// Ctrl/Cmd+S 立即保存通知（Shell 全局处理）。
  final ValueNotifier<int>? saveTick;

  /// Ctrl/Cmd+F 打开查找通知（Shell 全局拦截，避免落入 Quill 内置搜索框）。
  final ValueNotifier<int>? findTick;

  /// 同步引擎（null = 未接线，如单测）。
  final BackupManager? backup;

  /// 崩溃日志（null = 未接线，如测试）。
  final CrashJournal? journal;

  /// 本地诊断日志（null = 未接线，如测试）。
  final AppLogger? logger;

  /// 单文档版本历史（null = 未接线，如测试；顶栏隐藏入口且不自动留底）。
  final SnapshotHistory? snapshots;

  /// 全书搜索跳转请求（null = 未接线）。编辑器消费后置回 null。
  final ValueNotifier<EditorJumpRequest?>? jumpRequest;

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  late final q.QuillController _quill;
  final GlobalKey<q.QuillRawEditorState> _editorKey = GlobalKey<q.QuillRawEditorState>();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scroll = ScrollController();

  /// 焦点暗淡蒙层宿主 Stack 的 key（painter 用它做坐标换算锚点）。
  final GlobalKey _dimStackKey = GlobalKey();
  final Debouncer _saveDebounce = Debouncer(
    const Duration(milliseconds: _autoSaveDebounceMs),
  );
  final Debouncer _journalDebounce = Debouncer(
    const Duration(milliseconds: _journalThrottleMs),
  );

  StreamSubscription<q.DocChange>? _changesSub;

  /// 标点配对修正的防递归闸：修正动作（补插/删除）会再次触发 change。
  bool _bracketBusy = false;

  /// 上次成功保存的内容（Delta JSON），避免空保存。
  String _lastSavedContent = '';

  /// 从上次保存起实际新增的字数；删除不倒扣今日产出。
  int _pendingWrittenWords = 0;
  int _lastObservedWords = 0;

  /// 保存串行化，防止自动保存与切换前保存竞态。
  Future<void>? _saveInFlight;

  /// 崩溃恢复待确认项。
  CrashJournalEntry? _pendingRecover;

  // ── 斜杠命令菜单状态（overlay 承载，锚定光标）─────────────
  OverlayEntry? _slashOverlay;
  int _slashAnchor = -1;
  List<SlashCommand> _slashMatches = kSlashCommands;
  int _slashIndex = 0;
  Offset _slashPosition = Offset.zero;
  bool _slashKeyHandlerAdded = false;

  /// 编辑器当前已装载的文档 id（切换检测不能比较 widget.library ——
  /// 前后是同一个 controller 实例，currentDocument 永远相等）。
  String? _loadedDocumentId;

  // ── 大纲面板状态 ──────────────────────────────────────────
  final Debouncer _outlineDebounce = Debouncer(
    const Duration(milliseconds: _outlineDebounceMs),
  );
  List<OutlineEntry> _outlineEntries = const [];
  int _outlineActive = -1;

  /// 收起态右缘热区 hover 唤出的浮层是否可见（仅桌面）。
  bool _outlineHoverVisible = false;

  // ── 查找/替换状态（当前文档范围）──────────────────────────
  final GlobalKey<FindBarState> _findBarKey = GlobalKey<FindBarState>();
  bool _findOpen = false;
  String _findQuery = '';
  List<FindMatch> _findMatches = const [];
  int _findIndex = -1;

  @override
  void initState() {
    super.initState();
    _quill = q.QuillController(
      document: _documentFromCurrent(),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _loadedDocumentId = widget.library.currentDocument?.id;
    _lastSavedContent = widget.library.currentDocument?.content ?? '';
    _lastObservedWords = _countWords();
    _changesSub = _quill.document.changes.listen(_onDocChange);
    _quill.addListener(_onQuillChanged);
    _scroll.addListener(_onEditorScrolled);
    _focusNode.addListener(_onFocusChanged);
    widget.library.addListener(_onLibraryChanged);
    widget.toolbarDismissTick?.addListener(_onDismissToolbar);
    widget.saveTick?.addListener(_onSaveTick);
    widget.findTick?.addListener(_onFindTick);
    widget.jumpRequest?.addListener(_onJumpRequest);
    // 切换/退出前先保存（防丢）。
    widget.library.beforeSwitchSave = _saveNow;
    _checkRecovery();
    _refreshOutline();
    // 监听 IME 组合状态：组合阶段不触发保存/字数刷新。
    WidgetsBinding.instance.addPostFrameCallback((_) => _attachComposingListener());
    // 全书搜索切换文档后：新编辑器实例装载完成，消费待跳转（需等首帧布局）。
    if (widget.jumpRequest?.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _consumeJump());
    }
  }

  /// 库状态变化 → 当前文档 id 与已装载不一致时重载编辑器内容。
  void _onLibraryChanged() {
    final doc = widget.library.currentDocument;
    if (doc?.id == _loadedDocumentId) return;
    if (doc != null) {
      _loadDocument(doc);
    } else {
      _loadedDocumentId = null;
      _saveDebounce.cancel();
      _journalDebounce.cancel();
      _notesDebounce.cancel();
      _closeSlash();
      _changesSub?.cancel();
      _quill.document = q.Document();
      _changesSub = _quill.document.changes.listen(_onDocChange);
      _lastSavedContent = '';
      _pendingWrittenWords = 0;
      _lastObservedWords = 0;
      _closeFind(refocusEditor: false);
      _refreshOutline();
    }
  }

  @override
  void didUpdateWidget(covariant EditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 从沉浸退出（Esc / 悬浮工具栏 / Android 返回）后把焦点交还编辑器。
    if (oldWidget.focusMode && !widget.focusMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _closeSlash();
    _changesSub?.cancel();
    _detachComposingListener();
    _quill.removeListener(_onQuillChanged);
    _quill.dispose();
    _focusNode.dispose();
    _scroll.dispose();
    widget.library.removeListener(_onLibraryChanged);
    _saveDebounce.cancel();
    _journalDebounce.cancel();
    _outlineDebounce.cancel();
    _notesDebounce.cancel();
    widget.toolbarDismissTick?.removeListener(_onDismissToolbar);
    widget.saveTick?.removeListener(_onSaveTick);
    widget.findTick?.removeListener(_onFindTick);
    widget.jumpRequest?.removeListener(_onJumpRequest);
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

  // ── IME 组合状态追踪 ────────────────────────────────────────

  /// 监听编辑器的 composingRange，更新全局 [imeComposing] 状态。
  void _attachComposingListener() {
    final state = _editorKey.currentState;
    if (state == null) return;
    state.composingRange.addListener(_onComposingChanged);
    _onComposingChanged();
  }

  void _detachComposingListener() {
    final state = _editorKey.currentState;
    state?.composingRange.removeListener(_onComposingChanged);
    imeComposing.value = false;
  }

  void _onComposingChanged() {
    final state = _editorKey.currentState;
    final range = state?.composingRange.value;
    imeComposing.value = range != null && range.isValid && !range.isCollapsed;
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
    _loadedDocumentId = doc.id;
    _saveDebounce.cancel();
    _journalDebounce.cancel();
    _notesDebounce.cancel();
    _closeSlash();
    _changesSub?.cancel();
    _quill.document = _documentFromJson(doc.content);
    _quill.updateSelection(
      const TextSelection.collapsed(offset: 0),
      q.ChangeSource.local,
    );
    _changesSub = _quill.document.changes.listen(_onDocChange);
    _lastSavedContent = doc.content;
    _pendingWrittenWords = 0;
    _lastObservedWords = _countWords();
    widget.library.reportLiveWords(doc.words);
    _closeFind(refocusEditor: false);
    _refreshOutline();
  }

  // ── 变更 → 字数 / 自动保存 / 崩溃日志 / 斜杠菜单 ────────────

  /// 当前字数（按设置决定是否计入标点）。
  int _countWords() =>
      wordCount(_quill.document.toPlainText(),
          countPunctuation: widget.settings.settings.countPunctuation);

  void _onDocChange(q.DocChange change) {
    // IME 组合阶段（拼音未确认）的变更不触发保存/字数/大纲刷新，
    // 避免中间态写入崩溃日志或触发自动保存。组合结束后会再触发一次变更。
    if (isImeComposing) {
      _handleSlashTrigger(change);
      return;
    }
    _handleBracketPair(change);
    final words = _countWords();
    final delta = words > _lastObservedWords ? words - _lastObservedWords : 0;
    if (delta > 0) {
      _pendingWrittenWords += delta;
      widget.library.session.onWordsWritten(delta);
    }
    _lastObservedWords = words;
    widget.library.reportLiveWords(words);
    _saveDebounce.schedule(_saveNow);
    _journalDebounce.schedule(_writeJournal);
    _outlineDebounce.schedule(_refreshOutline);
    if (_findOpen) _recomputeMatches(select: false);
    _handleSlashTrigger(change);
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) {
      _saveDebounce.flush(_saveNow); // 失焦立即保存
    }
  }

  /// 保存当前缓冲：成功清崩溃日志 + 闪「已保存」；失败保留缓冲 + 错误条。
  ///
  /// 入口到 `_saveInFlight` 赋值之间不得有 await：Cmd+S 会经全局 handler
  /// 与编辑器 Shortcuts 两条路径各触发一次，靠该同步窗口串行化去重。
  Future<void> _saveNow() async {
    final activeSave = _saveInFlight;
    if (activeSave != null) await activeSave;

    final cur = widget.library.currentDocument;
    final documentId = _loadedDocumentId;
    if (cur == null || documentId == null || cur.id != documentId) return;
    final content = jsonEncode(_quill.document.toDelta().toJson());
    final writtenWords = _pendingWrittenWords;
    if (content == _lastSavedContent && writtenWords == 0) return;

    final operation = _performSave(
      previous: cur,
      content: content,
      writtenWords: writtenWords,
      nextWords: _lastObservedWords,
    );
    _saveInFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(_saveInFlight, operation)) _saveInFlight = null;
    }
  }

  Future<void> _performSave({
    required m.Document previous,
    required String content,
    required int writtenWords,
    required int nextWords,
  }) async {
    final documentId = previous.id;
    // 写库前自动留底（基线/大删除/超时间隔，见 SnapshotPolicy）：快照的是
    // 库中旧内容，大段误删后可从版本历史找回。失败只记日志，不阻塞保存。
    final snapshots = widget.snapshots;
    if (snapshots != null && content != previous.content) {
      try {
        await snapshots.maybeAutoSnapshot(previous, nextWords: nextWords);
      } catch (error, stackTrace) {
        await widget.logger?.warning(
          'snapshot.auto.failed',
          message: error.toString(),
          data: {'stackTrace': stackTrace.toString()},
        );
      }
    }
    try {
      await widget.library.saveDocument(
        documentId: documentId,
        title: previous.title,
        content: content,
        writtenWords: writtenWords,
      );
      // 保存期间可能已切换文档；旧结果不得污染新文档的基线。
      if (_loadedDocumentId != documentId) return;
      _lastSavedContent = content;
      _pendingWrittenWords = math.max(0, _pendingWrittenWords - writtenWords);
      widget.library.savedAt.value = DateTime.now();
      widget.library.clearSaveError();
      await widget.journal?.clear();
    } catch (error, stackTrace) {
      await widget.logger?.error('document.save.failed', error, stackTrace);
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

  // ── 版本历史（ui-editor.md §版本历史）─────────────────────

  /// 顶栏入口：先 flush 缓冲，保证历史列表与预览基于屏幕所见内容。
  Future<void> _showHistory() async {
    final snapshots = widget.snapshots;
    if (snapshots == null) return;
    await _saveNow();
    final doc = widget.library.currentDocument;
    if (doc == null || doc.id != _loadedDocumentId || !mounted) return;
    await showSnapshotHistory(
      context,
      history: snapshots,
      document: doc,
      onRestore: _restoreSnapshot,
    );
  }

  /// 回滚：当前内容先留底，再写库并就地重载编辑器。
  ///
  /// 必须显式重载：文档 id 未变，`_onLibraryChanged` 不会触发装载，
  /// 否则编辑器旧缓冲会在下次自动保存时把回滚结果覆盖回去。
  Future<bool> _restoreSnapshot(DocumentSnapshot snapshot) async {
    final snapshots = widget.snapshots;
    final documentId = _loadedDocumentId;
    final cur = widget.library.currentDocument;
    if (snapshots == null ||
        cur == null ||
        documentId == null ||
        cur.id != documentId ||
        snapshot.documentId != documentId) {
      return false;
    }
    try {
      await snapshots.create(cur);
      await widget.library.saveDocument(
        documentId: documentId,
        title: cur.title,
        content: snapshot.content,
        writtenWords: 0,
      );
      final restored = widget.library.currentDocument;
      if (!mounted || restored == null || restored.id != documentId) {
        return true;
      }
      _loadDocument(restored);
      showZzToast(context, '已回滚，之前的内容仍在版本历史里');
      return true;
    } catch (error, stackTrace) {
      await widget.logger?.error('snapshot.restore.failed', error, stackTrace);
      if (mounted) showZzToast(context, '回滚失败，请重试', error: true);
      return false;
    }
  }

  // ── 全书搜索跳转（ui-sidebar.md §全书搜索）────────────────

  void _onJumpRequest() => _consumeJump();

  /// 目标文档已装载时选中命中词并滚动定位；消费后清空请求。
  void _consumeJump() {
    final notifier = widget.jumpRequest;
    final request = notifier?.value;
    if (notifier == null || request == null || !mounted) return;
    if (request.documentId != _loadedDocumentId) return;
    notifier.value = null;
    final length = _quill.document.length;
    final start = request.offset.clamp(0, math.max(0, length - 1)).toInt();
    final end = (request.offset + request.length)
        .clamp(start, math.max(start, length - 1))
        .toInt();
    _quill.updateSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      q.ChangeSource.local,
    );
    _revealOffset(start);
    _focusNode.requestFocus();
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

  /// 标点自动配对：change 插入的末字符是括号时修正（补全闭括号 / 跳过）。
  ///
  /// 用 document.changes 而非字符事件：中文标点经 IME 提交，字符事件只覆盖
  /// 物理键输入。修正动作（补插/删除）会再次触发 change，用 [_bracketBusy]
  /// 防递归；修正结果再走一次字数/自动保存等常规流程。
  void _handleBracketPair(q.DocChange change) {
    if (_bracketBusy) return;
    final inserted = _insertedText(change);
    if (inserted == null || inserted.isEmpty) return;
    final typed = inserted[inserted.length - 1];
    if (!_bracketChars.contains(typed)) return;
    final sel = _quill.selection;
    if (!sel.isValid || !sel.isCollapsed) return;
    final pos = sel.baseOffset - 1; // typed 的插入位置
    if (pos < 0) return;
    final text = _quill.document.toPlainText();
    if (pos >= text.length || text[pos] != typed) return;
    // 还原插入前状态做判定（bracketPairCorrection 以插入前文本为输入）。
    final before = text.substring(0, pos) + text.substring(pos + 1);
    final correction = bracketPairCorrection(before, pos, typed);
    if (correction == null) return;
    final (_, cursor) = correction;
    _bracketBusy = true;
    try {
      if (_bracketClosing.contains(typed)) {
        // 跳过：删除刚输入的闭括号，光标越过补全的闭括号。
        _quill.replaceText(
          pos,
          1,
          '',
          TextSelection.collapsed(offset: cursor),
        );
      } else {
        // 补全：插入对应闭括号，光标停在中间。
        _quill.replaceText(
          pos + 1,
          0,
          _bracketPairs[typed]!,
          TextSelection.collapsed(offset: cursor),
        );
      }
    } finally {
      _bracketBusy = false;
    }
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
    _updateOutlineActive();
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
    final query = plain.substring(
      _slashAnchor + 1,
      math.min(caret, plain.length),
    );
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
        pos.dx.clamp(
          8.0,
          math.max(8.0, screen.width - SlashMenuPanel.width - 8),
        ),
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

  // ── 大纲面板 ──────────────────────────────────────────────

  void _refreshOutline() {
    if (!mounted) return;
    final entries = extractOutline(_quill.document.toDelta().toJson());
    if (entries.toString() == _outlineEntries.toString()) {
      _updateOutlineActive();
      return;
    }
    setState(() {
      _outlineEntries = entries;
      _outlineActive = _outlineActive.clamp(-1, entries.length - 1).toInt();
    });
    _updateOutlineActive();
  }

  /// 跟随高亮：视口上 1/3 线以上最近的标题（滚动/光标移动触发）。
  void _updateOutlineActive() {
    if (_outlineEntries.isEmpty) {
      if (_outlineActive != -1) setState(() => _outlineActive = -1);
      return;
    }
    if (!_scroll.hasClients) return;
    final render = _editorKey.currentState?.renderEditor;
    if (render == null || !render.attached) return;
    final threshold =
        _scroll.offset + _scroll.position.viewportDimension / 3;
    var active = 0;
    for (var i = 0; i < _outlineEntries.length; i++) {
      final rect = render.getLocalRectForCaret(
        TextPosition(offset: _outlineEntries[i].offset),
      );
      if (rect.top <= threshold) {
        active = i;
      } else {
        break;
      }
    }
    if (active != _outlineActive) setState(() => _outlineActive = active);
  }

  /// 点击跳转：光标至标题行首，标题滚动到视口上 1/3 处。
  void _jumpToOutline(OutlineEntry entry) {
    final length = _quill.document.length;
    final offset = entry.offset.clamp(0, math.max(0, length - 1)).toInt();
    _quill.updateSelection(
      TextSelection.collapsed(offset: offset),
      q.ChangeSource.local,
    );
    _revealOffset(offset);
    _focusNode.requestFocus();
    setState(() => _outlineHoverVisible = false);
  }

  /// 把 [offset] 所在行滚动到视口上 1/3 处。
  void _revealOffset(int offset) {
    if (!_scroll.hasClients) return;
    final render = _editorKey.currentState?.renderEditor;
    if (render == null || !render.attached) return;
    final rect = render.getLocalRectForCaret(TextPosition(offset: offset));
    final target = (rect.top - _scroll.position.viewportDimension / 3).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _toggleOutline() async {
    final next = !widget.settings.outlineOpen;
    setState(() => _outlineHoverVisible = false);
    await widget.settings.setOutlineOpen(next);
    if (mounted) setState(() {});
  }

  // ── 焦点暗淡 ──────────────────────────────────────────────

  /// 切换「暗淡非当前行」：写入 settings（持久化），编辑区随之挂载/卸载蒙层。
  Future<void> _toggleFocusDim() async {
    final next = !widget.settings.settings.focusDim;
    await widget.settings.update(
      widget.settings.settings.copyWith(focusDim: next),
    );
  }

  // ── 章节备注 ──────────────────────────────────────────────

  Future<void> _toggleNotes() async {
    final next = !widget.settings.notesOpen;
    await widget.settings.setNotesOpen(next);
    if (mounted) setState(() {});
  }

  /// 备注防抖保存。
  final Debouncer _notesDebounce = Debouncer(const Duration(milliseconds: 800));

  void _onNotesChanged(String notes) {
    final doc = widget.library.currentDocument;
    if (doc == null) return;
    _notesDebounce.schedule(() async {
      await widget.library.setDocumentNotes(doc.id, notes);
    });
  }

  // ── 查找/替换（当前文档范围）──────────────────────────────

  void _onFindTick() {
    if (widget.library.currentDocument != null) _openFind();
  }

  void _openFind() {
    // 有选中文本时带入作为初始查询（惯例行为）。
    final sel = _quill.selection;
    String initial = _findQuery;
    if (sel.isValid && !sel.isCollapsed) {
      final selected = _quill.document
          .toPlainText()
          .substring(sel.start, math.min(sel.end, sel.start + 64));
      if (!selected.contains('\n') && selected.trim().isNotEmpty) {
        initial = selected;
      }
    }
    if (_findOpen) {
      _findBarKey.currentState?.focusQuery();
      return;
    }
    setState(() {
      _findOpen = true;
      _findQuery = initial;
    });
    if (initial.isNotEmpty) _recomputeMatches(select: true);
  }

  void _closeFind({bool refocusEditor = true}) {
    if (!_findOpen) return;
    setState(() {
      _findOpen = false;
      _findMatches = const [];
      _findIndex = -1;
    });
    if (refocusEditor) _focusNode.requestFocus();
  }

  void _onFindQueryChanged(String query) {
    _findQuery = query;
    _recomputeMatches(select: true);
  }

  /// 重算匹配。[select] 时选中当前匹配并滚动定位；
  /// 文档编辑触发的重算只刷新计数，不打断输入。
  void _recomputeMatches({required bool select}) {
    final plain = _quill.document.toPlainText();
    final matches = findMatches(plain, _findQuery);
    // 尽量停留在原激活匹配附近。
    final anchor = _findIndex >= 0 && _findIndex < _findMatches.length
        ? _findMatches[_findIndex].offset
        : (_quill.selection.isValid ? _quill.selection.start : 0);
    final index = nextMatchIndex(matches, anchor);
    setState(() {
      _findMatches = matches;
      _findIndex = index;
    });
    if (select && index >= 0) _selectMatch(index);
  }

  void _selectMatch(int index) {
    if (index < 0 || index >= _findMatches.length) return;
    final match = _findMatches[index];
    setState(() => _findIndex = index);
    _quill.updateSelection(
      TextSelection(baseOffset: match.offset, extentOffset: match.end),
      q.ChangeSource.local,
    );
    _revealOffset(match.offset);
  }

  void _findNext() {
    if (_findMatches.isEmpty) return;
    _selectMatch((_findIndex + 1) % _findMatches.length);
  }

  void _findPrev() {
    if (_findMatches.isEmpty) return;
    _selectMatch(
      (_findIndex - 1 + _findMatches.length) % _findMatches.length,
    );
  }

  void _replaceCurrent(String replacement) {
    if (_findIndex < 0 || _findIndex >= _findMatches.length) return;
    final match = _findMatches[_findIndex];
    _quill.replaceText(
      match.offset,
      match.length,
      replacement,
      TextSelection.collapsed(offset: match.offset + replacement.length),
    );
    // 文档变更监听已刷新匹配；定位到下一个（偏移承接替换后文本）。
    final matches = findMatches(_quill.document.toPlainText(), _findQuery);
    final index = nextMatchIndex(matches, match.offset + replacement.length);
    setState(() {
      _findMatches = matches;
      _findIndex = index;
    });
    if (index >= 0) _selectMatch(index);
  }

  void _replaceAll(String replacement) {
    final matches = List.of(_findMatches);
    if (matches.isEmpty) return;
    // 从后往前替换，前面的偏移不受影响。
    for (final match in matches.reversed) {
      _quill.replaceText(
        match.offset,
        match.length,
        replacement,
        TextSelection.collapsed(offset: match.offset + replacement.length),
      );
    }
    setState(() {
      _findMatches = const [];
      _findIndex = -1;
    });
    showZzToast(context, '已替换 ${matches.length} 处');
  }

  // ── 链接 ──────────────────────────────────────────────────

  static String _normalizeUrl(String url) =>
      url.contains('://') || url.startsWith('mailto:') ? url : 'https://$url';

  /// 清除格式：移除选区（或光标处）的行内样式与块级样式，回到正文。
  void _clearFormat() {
    for (final attr in <q.Attribute<dynamic>>[
      q.Attribute.bold,
      q.Attribute.italic,
      q.Attribute.underline,
      q.Attribute.strikeThrough,
      q.Attribute.inlineCode,
      q.Attribute.link,
      q.Attribute.header,
      q.Attribute.list,
      q.Attribute.blockQuote,
      q.Attribute.codeBlock,
    ]) {
      _quill.formatSelection(q.Attribute.clone(attr, null));
    }
  }

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
          child: ZzTextField(
            controller: input,
            hint: 'https://…',
            autofocus: true,
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
    final goal = widget.settings.goalForNotebook(doc?.notebookId);
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
        // Ctrl/Cmd+F 查找/替换（当前文档）。
        SingleActivator(LogicalKeyboardKey.keyF, meta: meta, control: !meta):
            _FindIntent(),
      },
      child: Actions(
        actions: {
          _SaveIntent: CallbackAction(
            onInvoke: (_) {
              _saveNow();
              return true;
            },
          ),
          _FindIntent: CallbackAction(
            onInvoke: (_) {
              if (doc != null) _openFind();
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
            if (!focusMode) ...[
              _EditorHeader(
                title: doc?.title ?? '',
                notebookName: notebookName,
                onRename: doc == null
                    ? null
                    : (name) async {
                        try {
                          await widget.library.renameDocument(doc.id, name);
                          await widget.logger?.info(
                            'document.renamed',
                            data: {'documentId': doc.id},
                          );
                        } catch (error, stackTrace) {
                          await widget.logger?.error(
                            'document.rename.failed',
                            error,
                            stackTrace,
                            data: {'documentId': doc.id},
                          );
                          rethrow;
                        }
                      },
                validateTitle: doc == null
                    ? null
                    : (name) {
                        if (name.contains('/') || name.contains('\\')) {
                          return '标题不能包含 / 或 \\';
                        }
                        final duplicate = widget.library
                            .documentsOf(doc.notebookId)
                            .any(
                              (candidate) =>
                                  candidate.id != doc.id &&
                                  candidate.title == name,
                            );
                        return duplicate ? '同名章节已存在' : null;
                      },
                onToggleFocusMode: widget.onToggleFocusMode,
                onOpenFind: doc == null ? null : _openFind,
                onShowHistory: doc == null || widget.snapshots == null
                    ? null
                    : _showHistory,
                outlineOpen: widget.settings.outlineOpen,
                onToggleOutline: doc == null ? null : _toggleOutline,
                notesOpen: widget.settings.notesOpen,
                onToggleNotes: doc == null ? null : _toggleNotes,
                focusDim: s.focusDim,
                onToggleFocusDim: _toggleFocusDim,
                sidebarVisible: widget.sidebarVisible,
                onToggleSidebar: widget.onToggleSidebar,
              ),
              // 常驻格式工具栏：字体样式始终可见，不随选区隐藏。
              _FormatToolbar(
                quill: _quill,
                onLink: _promptLink,
                onClear: _clearFormat,
              ),
            ],
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
                  dailyGoal: goal.words,
                  goalEnabled: goal.enabled,
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
                onOpenSettings: widget.onOpenSettings,
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
    final editor = Theme(
      // flutter_quill 会把 macOS 当作 iOS 绘制带偏移的圆角光标。
      // 桌面端强制使用 Material 光标：2px、无偏移、accent 色。
      data: Theme.of(context).copyWith(
        platform: isDesktopPlatform
            ? TargetPlatform.windows
            : Theme.of(context).platform,
      ),
      child: q.QuillEditor(
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
          textSelectionThemeData: TextSelectionThemeData(
            cursorColor: colors.primary,
            selectionColor: colors.primary.withValues(alpha: 0.22),
            selectionHandleColor: colors.primary,
          ),
          paintCursorAboveText: false,
          characterShortcutEvents: q.standardCharactersShortcutEvents,
          spaceShortcutEvents: _spaceShortcuts,
          // 拦截 flutter_quill 内置的 Cmd/Ctrl+F（其 OpenSearchIntent 会弹
          // 未接本地化的空白搜索对话框 = 白蒙层），改走应用自己的查找/替换条。
          // customShortcuts 在 quill 合并快捷键时优先于默认值，因此其内置
          // 搜索框不会触发；_FindIntent 交由外层 Actions 处理（与编辑器外层
          // Shortcuts 一致）。
          customShortcuts: {
            SingleActivator(
              LogicalKeyboardKey.keyF,
              meta: isMacOS,
              control: !isMacOS,
            ): _FindIntent(),
          },
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
      ),
    );
    final windowWidth = MediaQuery.sizeOf(context).width;
    // 常驻面板：展开 + 非沉浸 + 窗口足够宽；否则（桌面）右缘热区悬浮。
    final showDockedOutline =
        hasDoc &&
        !focusMode &&
        widget.settings.outlineOpen &&
        windowWidth >= _outlineMinWindowWidth;
    final showDockedNotes =
        hasDoc &&
        !focusMode &&
        widget.settings.notesOpen &&
        windowWidth >= _outlineMinWindowWidth;
    final hoverOutlineAvailable =
        hasDoc && isDesktopPlatform && !showDockedOutline;
    final appColors = appColorsOf(context);
    final editorStack = Stack(
      children: [
        Positioned.fill(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxContentWidth),
              // 焦点暗淡：编辑器 + 上/下暗带 overlay（ui-editor.md §焦点暗淡）。
              child: s.focusDim && hasDoc
                  ? _FocusDimStack(
                      stackKey: _dimStackKey,
                      editorKey: _editorKey,
                      controller: _quill,
                      scrollController: _scroll,
                      dimColor: Theme.of(
                        context,
                      ).scaffoldBackgroundColor.withValues(alpha: 0.6),
                      child: editor,
                    )
                  : editor,
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
        // 查找/替换条：编辑区右上角浮层。
        if (_findOpen && hasDoc && !focusMode)
          Positioned(
            top: 10,
            right: 14,
            child: Focus(
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  _closeFind();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: FindBar(
                key: _findBarKey,
                initialQuery: _findQuery,
                matchCount: _findMatches.length,
                currentIndex: _findIndex,
                onQueryChanged: _onFindQueryChanged,
                onNext: _findNext,
                onPrev: _findPrev,
                onReplace: _replaceCurrent,
                onReplaceAll: _replaceAll,
                onClose: _closeFind,
              ),
            ),
          ),
        // 沉浸模式（桌面）：顶部浮出精简悬浮工具栏（前置退出按钮 + 核心格式）。
        // Android 走 FocusView 的顶部热区 + 系统返回，不叠加此条。
        if (focusMode && hasDoc && !isAndroidPlatform)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: _FocusToolbar(
              quill: _quill,
              onLink: _promptLink,
              onExit: widget.onToggleFocusMode,
            ),
          ),
        // 收起态右缘 8px 热区：hover 唤出大纲浮层（不拦截编辑区滚动）。
        if (hoverOutlineAvailable && !_outlineHoverVisible)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 8,
            child: MouseRegion(
              opaque: false,
              onEnter: (_) => setState(() => _outlineHoverVisible = true),
            ),
          ),
        if (hoverOutlineAvailable && _outlineHoverVisible)
          Positioned(
            right: 0,
            top: 8,
            bottom: 8,
            child: MouseRegion(
              onExit: (_) => setState(() => _outlineHoverVisible = false),
              child: GlassSurface(
                radius: 8,
                shadow: true,
                color: appColors.surfaceRaised,
                border: Border.all(color: colors.outline),
                child: OutlinePanel(
                  entries: _outlineEntries,
                  activeIndex: _outlineActive,
                  onJump: _jumpToOutline,
                ),
              ),
            ),
          ),
      ],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: editorStack),
        if (showDockedOutline)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: colors.outline)),
            ),
            child: OutlinePanel(
              entries: _outlineEntries,
              activeIndex: _outlineActive,
              onJump: _jumpToOutline,
            ),
          ),
        if (showDockedNotes)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: colors.outline)),
            ),
            child: NotesPanel(
              notes: doc.notes,
              onChanged: _onNotesChanged,
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
}

/// 保存意图（Ctrl/Cmd+S）。
class _SaveIntent extends Intent {
  const _SaveIntent();
}

/// 查找意图（Ctrl/Cmd+F）。
class _FindIntent extends Intent {
  const _FindIntent();
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
    required this.onRename,
    required this.validateTitle,
    required this.onToggleFocusMode,
    this.onOpenFind,
    this.onShowHistory,
    this.outlineOpen = false,
    this.onToggleOutline,
    this.notesOpen = false,
    this.onToggleNotes,
    this.focusDim = false,
    this.onToggleFocusDim,
    this.sidebarVisible = false,
    this.onToggleSidebar,
  });

  final String title;
  final String? notebookName;
  final Future<void> Function(String name)? onRename;
  final String? Function(String name)? validateTitle;
  final VoidCallback onToggleFocusMode;
  final VoidCallback? onOpenFind;
  final VoidCallback? onShowHistory;
  final bool outlineOpen;
  final VoidCallback? onToggleOutline;
  final bool notesOpen;
  final VoidCallback? onToggleNotes;

  /// 焦点暗淡开关状态（active 态高亮）。
  final bool focusDim;
  final VoidCallback? onToggleFocusDim;

  /// 侧边栏可见状态与切换回调（null = 未接线，不显示按钮）。
  final bool sidebarVisible;
  final VoidCallback? onToggleSidebar;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return GlassSurface(
      color: Theme.of(context).scaffoldBackgroundColor,
      border: Border(bottom: BorderSide(color: colors.outline)),
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            // 侧边栏切换按钮：桌面显隐切换，Android 打开 Drawer（ui-shell.md
            // Interactions）。tooltip 带快捷键提示，兼顾「快捷键 + 可见入口」。
            if (onToggleSidebar != null) ...[
              const SizedBox(width: 6),
              _HeaderAction(
                onPressed: onToggleSidebar!,
                tooltip: isDesktopPlatform
                    ? (sidebarVisible
                          ? '收起侧边栏 (${isMacOS ? '⌘' : 'Ctrl'}+B)'
                          : '展开侧边栏 (${isMacOS ? '⌘' : 'Ctrl'}+B)')
                    : '打开侧边栏',
                icon: Icons.menu,
                active: sidebarVisible && isDesktopPlatform,
              ),
              const SizedBox(width: 10),
            ] else
              const SizedBox(width: 18),
            Icon(
              Icons.description_outlined,
              size: 16,
              color: appColors.textTertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: title.isEmpty
                  ? Text(
                      '未选择文档',
                      style: TextStyle(
                        fontSize: 13,
                        color: appColors.textTertiary,
                      ),
                    )
                  : Row(
                      children: [
                        if (notebookName != null) ...[
                          Flexible(
                            child: Text(
                              notebookName!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Text(
                            ' / ',
                            style: TextStyle(color: appColors.textTertiary),
                          ),
                        ],
                        Flexible(
                          child: _EditableHeaderTitle(
                            title: title,
                            onRename: onRename!,
                            validate: validateTitle!,
                          ),
                        ),
                      ],
                    ),
            ),
            if (onOpenFind != null)
              _HeaderAction(
                onPressed: onOpenFind!,
                tooltip: '查找/替换 (${isMacOS ? '⌘' : 'Ctrl'}+F)',
                icon: Icons.search,
              ),
            if (onShowHistory != null) ...[
              const SizedBox(width: 2),
              _HeaderAction(
                onPressed: onShowHistory!,
                tooltip: '版本历史',
                icon: Icons.history,
              ),
            ],
            if (onToggleOutline != null) ...[
              const SizedBox(width: 2),
              _HeaderAction(
                onPressed: onToggleOutline!,
                tooltip: outlineOpen ? '收起大纲' : '展开大纲',
                icon: Icons.toc,
                active: outlineOpen,
              ),
            ],
            if (onToggleNotes != null) ...[
              const SizedBox(width: 2),
              _HeaderAction(
                onPressed: onToggleNotes!,
                tooltip: notesOpen ? '收起备注' : '展开备注',
                icon: Icons.sticky_note_2_outlined,
                active: notesOpen,
              ),
            ],
            if (onToggleFocusDim != null) ...[
              const SizedBox(width: 2),
              _HeaderAction(
                onPressed: onToggleFocusDim!,
                tooltip: focusDim ? '关闭暗淡非当前行' : '暗淡非当前行',
                icon: Icons.contrast,
                active: focusDim,
              ),
            ],
            const SizedBox(width: 2),
            _HeaderAction(
              onPressed: onToggleFocusMode,
              tooltip: '沉浸模式 (${isMacOS ? '⌘' : 'Ctrl'}+Shift+F)',
              icon: Icons.open_in_full,
            ),
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}

/// 顶栏标题：静态展示，点击后原地编辑；Enter/失焦提交，Esc 取消。
class _EditableHeaderTitle extends StatefulWidget {
  const _EditableHeaderTitle({
    required this.title,
    required this.onRename,
    required this.validate,
  });

  final String title;
  final Future<void> Function(String name) onRename;
  final String? Function(String name) validate;

  @override
  State<_EditableHeaderTitle> createState() => _EditableHeaderTitleState();
}

class _EditableHeaderTitleState extends State<_EditableHeaderTitle> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.title,
  );
  final FocusNode _focusNode = FocusNode();
  bool _editing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _EditableHeaderTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing && oldWidget.title != widget.title) {
      _controller.text = widget.title;
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_editing && !_focusNode.hasFocus) _finish();
  }

  void _begin() {
    _controller
      ..text = widget.title
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.title.length,
      );
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _cancel() {
    _controller.text = widget.title;
    setState(() => _editing = false);
  }

  Future<void> _finish() async {
    if (!_editing || _saving) return;
    final name = _controller.text.trim();
    if (name.isEmpty) {
      _controller.text = widget.title;
      showZzToast(context, '标题不能为空', error: true);
      setState(() => _editing = false);
      return;
    }
    final validationError = widget.validate(name);
    if (validationError != null) {
      showZzToast(context, validationError, error: true);
      return;
    }
    if (name == widget.title) {
      setState(() => _editing = false);
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onRename(name);
      if (mounted) setState(() => _editing = false);
    } catch (error) {
      _controller.text = widget.title;
      if (mounted) {
        showZzToast(context, '标题保存失败：$error', error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (!_editing) {
      return Tooltip(
        message: '编辑标题',
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: _begin,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
          ),
        ),
      );
    }
    return Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _cancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SizedBox(
        height: 28,
        child: ZzTextField(
          controller: _controller,
          hint: '',
          focusNode: _focusNode,
          enabled: !_saving,
          compact: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _finish(),
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
    this.active = false,
  });

  final VoidCallback onPressed;
  final String tooltip;
  final IconData icon;

  /// 常亮态（如大纲面板展开时的入口 icon）。
  final bool active;

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
          borderRadius: BorderRadius.circular(4),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? appColors.surfaceHover
                  : widget.active
                  ? appColors.rowSelected
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: widget.active ? colors.onSurface : colors.onSurfaceVariant,
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

/// 格式按钮组：常驻工具栏与选区浮动工具栏共用同一套按钮。
///
/// [showHistory] 追加撤销/重做（常驻工具栏用）；[onClear] 非空时追加
/// 「清除格式」按钮。
class _FormatButtons extends StatelessWidget {
  const _FormatButtons({
    required this.quill,
    required this.onLink,
    this.showHistory = false,
    this.onClear,
    this.compact = false,
  });

  final q.QuillController quill;
  final VoidCallback onLink;
  final bool showHistory;
  final VoidCallback? onClear;

  /// 精简模式（沉浸悬浮工具栏）：只保留核心写作格式，去掉撤销/重做、链接、引用、代码与清除。
  final bool compact;

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
      bool enabled = true,
    }) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: enabled ? onTap : null,
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
                color: !enabled
                    ? appColors.textTertiary
                    : isActive
                    ? colors.onSurface
                    : colors.onSurfaceVariant,
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
            // 与图标按钮同尺寸（30×30），保证标题按钮与图标按钮视觉密度一致。
            width: 30,
            height: 30,
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

    final children = <Widget>[
      if (showHistory) ...[
        btn(
          icon: const Icon(Icons.undo),
          tooltip: '撤销',
          isActive: false,
          enabled: quill.hasUndo,
          onTap: quill.undo,
        ),
        btn(
          icon: const Icon(Icons.redo),
          tooltip: '重做',
          isActive: false,
          enabled: quill.hasRedo,
          onTap: quill.redo,
        ),
        _sep(colors),
      ],
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
      if (!compact) ...[
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
      ],
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
      if (!compact) ...[
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
        if (onClear != null) ...[
          _sep(colors),
          btn(
            icon: const Icon(Icons.format_clear),
            tooltip: '清除格式',
            isActive: false,
            onTap: onClear!,
          ),
        ],
      ],
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  Widget _sep(ColorScheme colors) => Container(
    width: 1,
    height: 18,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: colors.outline,
  );
}

/// 常驻格式工具栏：顶栏下方始终可见（沉浸模式除外），字体样式一目了然。
///
/// 监听控制器，选区/光标移动时实时高亮当前格式；含撤销/重做与清除格式。
class _FormatToolbar extends StatelessWidget {
  const _FormatToolbar({
    required this.quill,
    required this.onLink,
    required this.onClear,
  });

  final q.QuillController quill;
  final VoidCallback onLink;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: ListenableBuilder(
        listenable: quill,
        builder: (context, _) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _FormatButtons(
            quill: quill,
            onLink: onLink,
            showHistory: true,
            onClear: onClear,
          ),
        ),
      ),
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
    return GlassSurface(
      radius: 6,
      shadow: true,
      color: appColors.surfaceRaised,
      border: Border.all(color: colors.outline),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: _FormatButtons(quill: quill, onLink: onLink),
      ),
    );
  }
}

/// 沉浸模式精简悬浮工具栏：前置「退出沉浸」按钮 + 核心格式 + 进入时短暂提示。
///
/// 沉浸态不再隐藏全部 chrome：保留一个轻量悬浮条（核心写作格式），把退出入口
/// 提到最前并单独用 accent 色标注，进入时顶部短暂浮现「按 Esc 退出」提示后自动淡出。
class _FocusToolbar extends StatefulWidget {
  const _FocusToolbar({
    required this.quill,
    required this.onLink,
    required this.onExit,
  });

  final q.QuillController quill;
  final VoidCallback onLink;
  final VoidCallback onExit;

  @override
  State<_FocusToolbar> createState() => _FocusToolbarState();
}

class _FocusToolbarState extends State<_FocusToolbar> {
  bool _showHint = true;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    // 进入沉浸后短暂提示 exit，随后淡出（不打扰长期书写）。
    _hintTimer = Timer(const Duration(milliseconds: 2600), () {
      if (mounted) setState(() => _showHint = false);
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 进入提示：短暂浮现后淡出，不拦截交互。
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _showHint ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: appColors.surfaceRaised,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: colors.outline),
              ),
              child: Text(
                '沉浸模式 · 按 Esc 退出',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
          ),
        ),
        Center(
          child: GlassSurface(
            radius: 6,
            shadow: true,
            color: appColors.surfaceRaised,
            border: Border.all(color: colors.outline),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ExitButton(onExit: widget.onExit),
                Container(
                  width: 1,
                  height: 18,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  color: colors.outline,
                ),
                _FormatButtons(
                  quill: widget.quill,
                  onLink: widget.onLink,
                  compact: true,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 悬浮工具栏最前端的「退出沉浸」入口：accent 色做独立高亮。
class _ExitButton extends StatefulWidget {
  const _ExitButton({required this.onExit});

  final VoidCallback onExit;

  @override
  State<_ExitButton> createState() => _ExitButtonState();
}

class _ExitButtonState extends State<_ExitButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: '退出沉浸 (Esc)',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: widget.onExit,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? colors.primary.withValues(alpha: 0.14)
                  : colors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.fullscreen_exit, size: 15, color: colors.primary),
                const SizedBox(width: 5),
                Text(
                  '退出沉浸',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
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

// ── 焦点暗淡（Focus Dim）──────────────────────────────────
// 设计：docs/app/ui-editor.md §焦点暗淡。编辑器 + 上/下暗带 overlay，
// 亮区 = 光标（选区 base）所在段落块；跨段落选区 = base..extent 全部段落。

/// 焦点暗淡蒙层宿主：把编辑器包进 Stack，叠加一层 IgnorePointer 的 CustomPaint，
/// 对「当前段落块」上/下方绘制页面底色暗带（内容宽度内）。
///
/// 订阅 controller（选区/文档变更）与 scrollController（滚动）触发重绘，
/// 实现逐帧跟随；overlay 不拦截输入/滚动/选区。
class _FocusDimStack extends StatefulWidget {
  const _FocusDimStack({
    required this.stackKey,
    required this.editorKey,
    required this.controller,
    required this.scrollController,
    required this.dimColor,
    required this.child,
  });

  /// 宿主 Stack 的 key：painter 用它做 globalToLocal 坐标换算锚点。
  final GlobalKey stackKey;

  final GlobalKey<q.QuillRawEditorState> editorKey;
  final q.QuillController controller;
  final ScrollController scrollController;
  final Color dimColor;
  final Widget child;

  @override
  State<_FocusDimStack> createState() => _FocusDimStackState();
}

class _FocusDimStackState extends State<_FocusDimStack> {
  StreamSubscription<q.DocChange>? _docSub;

  @override
  void initState() {
    super.initState();
    _docSub = widget.controller.document.changes.listen((_) => _onInvalidated());
    widget.controller.addListener(_onInvalidated);
    widget.scrollController.addListener(_onInvalidated);
  }

  @override
  void dispose() {
    _docSub?.cancel();
    widget.controller.removeListener(_onInvalidated);
    widget.scrollController.removeListener(_onInvalidated);
    super.dispose();
  }

  /// 选区 / 文档变更 / 滚动时重绘暗带（geometry 由 painter 在 paint 时实时计算）。
  void _onInvalidated() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: widget.stackKey,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _FocusDimPainter(
                editorKey: widget.editorKey,
                controller: widget.controller,
                stackKey: widget.stackKey,
                dimColor: widget.dimColor,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FocusDimPainter extends CustomPainter {
  _FocusDimPainter({
    required this.editorKey,
    required this.controller,
    required this.stackKey,
    required this.dimColor,
  });

  final GlobalKey<q.QuillRawEditorState> editorKey;
  final q.QuillController controller;
  final GlobalKey stackKey;
  final Color dimColor;

  @override
  void paint(Canvas canvas, Size size) {
    final range = _highlightRange(size);
    if (range == null) return;
    final paint = Paint()..color = dimColor;
    final top = Rect.fromLTRB(0, 0, size.width, range.$1);
    if (top.height > 0) canvas.drawRect(top, paint);
    final bottom = Rect.fromLTRB(0, range.$2, size.width, size.height);
    if (bottom.height > 0) canvas.drawRect(bottom, paint);
  }

  /// 亮区（当前段落块）在宿主 Stack 坐标系下的 `[top, bottom]`；
  /// 无法计算（无文档 / 选区无效 / 编辑器未挂载）时返回 null，不绘制蒙层。
  (double, double)? _highlightRange(Size size) {
    final editorState = editorKey.currentState;
    final stackBox = stackKey.currentContext?.findRenderObject();
    if (editorState == null || stackBox is! RenderBox || !stackBox.hasSize) {
      return null;
    }
    final q.RenderEditor editor;
    try {
      editor = editorState.renderEditor;
    } catch (_) {
      return null; // 首帧尚未挂载。
    }
    if (!editor.attached || editor.firstChild == null) return null;

    final selection = controller.selection;
    if (!selection.isValid) return null;

    final base = _blockAt(editor, selection.baseOffset);
    final extent = _blockAt(editor, selection.extentOffset);
    if (base == null || extent == null) return null;

    // 跨段落选区：base..extent 覆盖的全部段落（按文档序取上下界）。
    var first = base;
    var last = extent;
    if (first.container.documentOffset > last.container.documentOffset) {
      first = extent;
      last = base;
    }
    final firstTop = (first.parentData as q.EditableContainerParentData).offset.dy;
    final lastBottom = (last.parentData as q.EditableContainerParentData).offset.dy +
        last.size.height;
    final localTop = stackBox.globalToLocal(
      editor.localToGlobal(Offset(0, firstTop)),
    ).dy;
    final localBottom = stackBox.globalToLocal(
      editor.localToGlobal(Offset(0, lastBottom)),
    ).dy;
    final top = localTop.clamp(0.0, size.height);
    final bottom = localBottom.clamp(0.0, size.height);
    if (bottom <= top) return null;
    return (top, bottom);
  }

  /// 文档偏移 [offset] 所在的段落渲染盒；越界（如光标在文末）取末尾块。
  /// 返回类型用推断，避免直接引用 flutter_quill 未导出的 `RenderEditableBox`。
  dynamic _blockAt(q.RenderEditor editor, int offset) {
    dynamic last;
    var child = editor.firstChild;
    while (child != null) {
      last = child;
      if (child.container.containsOffset(offset)) return child;
      child = editor.childAfter(child);
    }
    return last;
  }

  @override
  bool shouldRepaint(covariant _FocusDimPainter oldDelegate) => true;
}
