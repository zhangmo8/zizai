/// 库状态：目录树、当前文档、未保存缓冲、今日增量、删除确认请求。
///
/// 设计依据：docs/app/README.md §6（状态流：library_controller 是状态所有者）、
/// docs/app/ui-shell.md（State Variants）、docs/app/ui-sidebar.md（CRUD 交互）。
library;

import 'package:flutter/foundation.dart';

import '../core/db.dart';
import '../core/models.dart';

/// 待删除对象类型（删除确认条用）。
enum DeletionKind { notebook, document }

/// 删除确认请求：非模态确认条（5s 无操作自动取消）。
class DeletionRequest {
  const DeletionRequest({
    required this.kind,
    required this.id,
    required this.name,
  });

  final DeletionKind kind;
  final String id;
  final String name;
}

class LibraryController extends ChangeNotifier {
  LibraryController(this._db);

  final Db _db;

  List<Notebook> _notebooks = const [];
  List<Notebook> get notebooks => _notebooks;

  Map<String, List<Document>> _documentsByNotebook = const {};
  List<Document> documentsOf(String notebookId) =>
      _documentsByNotebook[notebookId] ?? const [];

  /// 当前库内全部文档，按笔记本和章节顺序展平，供整书导出使用。
  List<Document> get allDocuments => [
    for (final notebook in _notebooks) ...documentsOf(notebook.id),
  ];

  Document? _currentDocument;
  Document? get currentDocument => _currentDocument;

  int _todayDelta = 0;
  int get todayDelta => _todayDelta;

  bool _loading = true;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  /// 实时本文字数（编辑器每次变更更新；null 时回退保存快照）。
  ///
  /// 用 ValueNotifier 而非 notifyListeners：字数每键都变，只有状态栏/
  /// 沉浸态字数条订阅它，避免整个 Shell 子树逐键重建。
  final ValueNotifier<int?> liveWords = ValueNotifier<int?>(null);
  int? get liveDocWords => liveWords.value;

  /// 保存失败信息（状态栏错误条 + 重试）。
  String? _saveError;
  String? get saveError => _saveError;

  /// 保存成功时刻（状态栏闪「已保存」1s）。
  final ValueNotifier<DateTime?> savedAt = ValueNotifier<DateTime?>(null);

  DeletionRequest? _pendingDeletion;
  DeletionRequest? get pendingDeletion => _pendingDeletion;

  /// edit-003 注入：切换文档 / 退出前先保存当前缓冲（防丢）。
  Future<void> Function()? beforeSwitchSave;

  /// 启动恢复：目录树 + 今日增量 + 按 last_open 打开上次文档。
  Future<void> restore() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await _reloadTree();
      final lastOpen = await _db.loadLastOpen();
      if (lastOpen?.documentId != null) {
        _currentDocument = await _db.getDocument(lastOpen!.documentId!);
      }
      await _refreshTodayDelta();
    } catch (e) {
      _error = '加载失败: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 切换文档：先保存旧文档缓冲（若有），再加载新文档。
  Future<void> switchDocument(String documentId) async {
    if (beforeSwitchSave != null) {
      await beforeSwitchSave!();
    }
    final doc = await _db.getDocument(documentId);
    if (doc == null) return;
    _currentDocument = doc;
    await _refreshTodayDelta();
    await _db.saveLastOpen(
      notebookId: doc.notebookId,
      documentId: doc.id,
      words: doc.words,
    );
    notifyListeners();
  }

  /// 保存当前文档（edit-003 自动保存调用）：返回字数增量并刷新今日增量/快照。
  Future<int> saveDocument({
    required String documentId,
    required String title,
    required String content,
    required int writtenWords,
  }) async {
    final delta = await _db.saveDocument(
      id: documentId,
      title: title,
      content: content,
      writtenWords: writtenWords,
    );
    final refreshed = await _db.getDocument(documentId);
    // 树缓存同步最新内容（全书搜索/整书导出直接读缓存，不能落后于库）。
    if (refreshed != null) _replaceInTree(refreshed);
    // 旧文档的异步保存可能在切换后才完成；禁止它覆盖当前文档。
    if (_currentDocument?.id == documentId) {
      _currentDocument = refreshed;
      await _refreshTodayDelta();
      notifyListeners();
    }
    return delta;
  }

  /// 兼容旧调用；编辑器应传入明确的 documentId 以避免切换竞态。
  Future<int> saveCurrentDocument({
    required String title,
    required String content,
  }) {
    final doc = _currentDocument;
    if (doc == null) throw StateError('无当前文档可保存');
    return saveDocument(
      documentId: doc.id,
      title: title,
      content: content,
      writtenWords: 0,
    );
  }

  // ── 笔记本 CRUD ───────────────────────────────────────────

  Future<Notebook> createNotebook(String name) async {
    final nb = await _db.createNotebook(name);
    await _reloadTree();
    return nb;
  }

  Future<void> renameNotebook(String id, String name) async {
    await _db.renameNotebook(id, name);
    await _reloadTree();
  }

  Future<void> deleteNotebook(String id) async {
    final cur = _currentDocument;
    if (cur != null && cur.notebookId == id) {
      _currentDocument = null;
    }
    await _db.deleteNotebook(id);
    await _reloadTree();
  }

  Future<void> moveNotebook(String id, {required bool up}) async {
    await _db.moveNotebook(id, up: up);
    await _reloadTree();
  }

  // ── 文档 CRUD ─────────────────────────────────────────────

  Future<Document> createDocument(
    String notebookId, {
    String title = '新章节.md',
  }) async {
    final doc = await _db.createDocument(notebookId, title: title);
    await _reloadTree();
    return doc;
  }

  Future<void> renameDocument(String id, String title) async {
    await _db.renameDocument(id, title);
    final cur = _currentDocument;
    if (cur != null && cur.id == id) {
      _currentDocument = await _db.getDocument(id);
    }
    await _reloadTree();
  }

  Future<void> deleteDocument(String id) async {
    final cur = _currentDocument;
    if (cur != null && cur.id == id) {
      _currentDocument = null;
    }
    await _db.deleteDocument(id);
    await _reloadTree();
  }

  Future<void> moveDocument(String id, {required bool up}) async {
    final cur = _currentDocument;
    final notebookId = cur != null && cur.id == id
        ? cur.notebookId
        : (await _db.getDocument(id))?.notebookId;
    if (notebookId == null) return;
    await _db.moveDocument(id, up: up);
    await _reloadTree();
    if (_currentDocument != null && _currentDocument!.id == id) {
      _currentDocument = await _db.getDocument(id);
      notifyListeners();
    }
  }

  // ── 删除确认（非模态，5s 自动关由 UI 层 Timer 驱动）──────────

  void requestDelete({
    required DeletionKind kind,
    required String id,
    required String name,
  }) {
    _pendingDeletion = DeletionRequest(kind: kind, id: id, name: name);
    notifyListeners();
  }

  Future<void> confirmDelete() async {
    final req = _pendingDeletion;
    if (req == null) return;
    _pendingDeletion = null;
    notifyListeners();
    if (req.kind == DeletionKind.notebook) {
      await deleteNotebook(req.id);
    } else {
      await deleteDocument(req.id);
    }
  }

  void cancelDelete() {
    if (_pendingDeletion == null) return;
    _pendingDeletion = null;
    notifyListeners();
  }

  // ── 内部 ──────────────────────────────────────────────────

  Future<void> _reloadTree() async {
    _notebooks = await _db.listNotebooks();
    final map = <String, List<Document>>{};
    for (final nb in _notebooks) {
      map[nb.id] = await _db.listDocuments(nb.id);
    }
    _documentsByNotebook = map;
    notifyListeners();
  }

  /// 保存后就地更新树缓存里的对应文档（不触发整树重载与通知）。
  void _replaceInTree(Document doc) {
    final docs = _documentsByNotebook[doc.notebookId];
    if (docs == null) return;
    final index = docs.indexWhere((d) => d.id == doc.id);
    if (index >= 0) docs[index] = doc;
  }

  Future<void> _refreshTodayDelta() async {
    _todayDelta = await _db.todayDelta(
      notebookId: _currentDocument?.notebookId,
    );
  }

  /// 实时字数上报（编辑器变更时）：只更新 ValueNotifier，不触发全树刷新。
  void reportLiveWords(int words) {
    liveWords.value = words;
  }

  @override
  void dispose() {
    savedAt.dispose();
    liveWords.dispose();
    super.dispose();
  }

  void reportSaveError(String message) {
    _saveError = message;
    notifyListeners();
  }

  void clearSaveError() {
    if (_saveError == null) return;
    _saveError = null;
    notifyListeners();
  }

  /// 存储错误后重试恢复。
  Future<void> retry() => restore();

  /// 记录错误（状态栏错误条消费）。
  void reportError(String message) {
    _error = message;
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }
}
