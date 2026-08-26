/// 库状态：目录树、当前文档、未保存缓冲、今日增量、删除确认请求。
///
/// 设计依据：docs/app/README.md §6（状态流：library_controller 是状态所有者）、
/// docs/app/ui-shell.md（State Variants）、docs/app/ui-sidebar.md（CRUD 交互）。
library;

import 'package:flutter/foundation.dart';

import '../core/chapter_ops.dart';
import '../core/db.dart';
import '../core/models.dart';
import '../core/writing_session.dart';
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

  /// 各笔记本的分卷（手动分卷真数据，按 position 排序）。
  Map<String, List<Volume>> _volumesByNotebook = const {};
  List<Volume> volumesOf(String notebookId) =>
      _volumesByNotebook[notebookId] ?? const [];

  /// 当前库内全部文档，按笔记本和章节顺序展平，供整书导出使用。
  List<Document> get allDocuments => [
    for (final notebook in _notebooks) ...documentsOf(notebook.id),
  ];

  Document? _currentDocument;
  Document? get currentDocument => _currentDocument;

  /// 当前打开的笔记本（单书工作区；null = 处于笔记本管理页）。
  Notebook? _currentNotebook;
  Notebook? get currentNotebook => _currentNotebook;

  Notebook? notebookById(String id) {
    for (final nb in _notebooks) {
      if (nb.id == id) return nb;
    }
    return null;
  }

  /// 某笔记本的总字数（章节 words 之和，卡片展示用）。
  int wordsOf(String notebookId) {
    var total = 0;
    for (final doc in documentsOf(notebookId)) {
      total += doc.words;
    }
    return total;
  }

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

  /// 写作会话追踪（本次字数/时长/速度）。编辑器上报增量，状态栏订阅显示。
  final WritingSession session = WritingSession();

  DeletionRequest? _pendingDeletion;
  DeletionRequest? get pendingDeletion => _pendingDeletion;

  /// edit-003 注入：切换文档 / 退出前先保存当前缓冲（防丢）。
  Future<void> Function()? beforeSwitchSave;

  /// 启动恢复：目录树 + 今日增量 + 恢复上次打开的笔记本（resume 进工作区；
  /// 无记录或书已不存在则停在笔记本管理页）。
  Future<void> restore() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await _reloadTree();
      final lastOpen = await _db.loadLastOpen();
      if (lastOpen?.notebookId != null &&
          notebookById(lastOpen!.notebookId!) != null) {
        await openNotebook(lastOpen.notebookId!);
      } else {
        await _refreshTodayDelta();
      }
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
    session.reset();
    await _db.saveLastOpen(
      notebookId: doc.notebookId,
      documentId: doc.id,
      words: doc.words,
    );
    notifyListeners();
  }

  /// 进入某本书（单书工作区）：设置当前笔记本，并打开该书上次的章节
  /// （无记录则打开第一章；无章节则保持无文档）。
  Future<void> openNotebook(String notebookId) async {
    if (beforeSwitchSave != null) {
      await beforeSwitchSave!();
    }
    final nb = notebookById(notebookId);
    if (nb == null) return;
    _currentNotebook = nb;
    // 优先恢复该书上次打开的章节；否则第一章节。
    final docs = documentsOf(notebookId);
    final lastOpen = await _db.loadLastOpen();
    String? docId;
    if (lastOpen?.notebookId == notebookId && lastOpen?.documentId != null) {
      docId = lastOpen!.documentId;
    } else if (docs.isNotEmpty) {
      docId = docs.first.id;
    }
    if (docId != null) {
      final doc = await _db.getDocument(docId);
      if (doc != null) {
        _currentDocument = doc;
        await _db.saveLastOpen(
          notebookId: doc.notebookId,
          documentId: doc.id,
          words: doc.words,
        );
      }
    } else {
      _currentDocument = null;
    }
    await _refreshTodayDelta();
    session.reset();
    notifyListeners();
  }

  /// 退出单书工作区回到笔记本管理页：清空当前笔记本与文档。
  Future<void> closeNotebook() async {
    if (beforeSwitchSave != null) {
      await beforeSwitchSave!();
    }
    _currentNotebook = null;
    _currentDocument = null;
    liveWords.value = null;
    session.reset();
    notifyListeners();
  }

  /// 手动刷新目录树（分卷数据装载；设置侧创建卷后调用）。
  Future<void> refreshTree() => _reloadTree();

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
    String? volumeId,
  }) async {
    final doc = await _db.createDocument(
      notebookId,
      title: title,
      volumeId: volumeId,
    );
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

  /// 拖拽重排：将文档移动到目标笔记本的指定位置。
  Future<void> reorderDocument(
    String id, {
    required String notebookId,
    required int newPosition,
  }) async {
    await _db.reorderDocument(id, notebookId: notebookId, newPosition: newPosition);
    await _reloadTree();
    if (_currentDocument != null && _currentDocument!.id == id) {
      _currentDocument = await _db.getDocument(id);
      notifyListeners();
    }
  }

  // ── 分卷 CRUD（手动分卷真数据） ──────────────────────────

  Future<Volume> createVolume(String notebookId, {String? name}) async {
    final vol = await _db.createVolume(notebookId, name: name);
    await _reloadTree();
    return vol;
  }

  Future<void> renameVolume(String id, String name) async {
    await _db.renameVolume(id, name);
    await _reloadTree();
  }

  Future<void> deleteVolume(String id) async {
    await _db.deleteVolume(id);
    await _reloadTree();
  }

  /// 删除分卷并连带删除卷内章节（product 约定：删除分卷 = 卷 + 卷内章节）。
  Future<void> deleteVolumeWithDocs(
    String id, {
    required List<String> documentIds,
  }) async {
    // 若删除卷正是当前打开的文档，先清空当前文档。
    final cur = _currentDocument;
    if (cur != null && documentIds.contains(cur.id)) {
      _currentDocument = null;
    }
    await _db.deleteVolumeWithDocs(id, documentIds: documentIds);
    await _reloadTree();
  }

  /// 把章节移到指定分卷的 [indexInVolume] 位（volumeId = null → 未分卷区）。
  Future<void> moveDocumentToVolume(
    String id, {
    required String? volumeId,
    required int indexInVolume,
  }) async {
    await _db.moveDocumentToVolume(
      id,
      volumeId: volumeId,
      indexInVolume: indexInVolume,
    );
    await _reloadTree();
    if (_currentDocument != null && _currentDocument!.id == id) {
      _currentDocument = await _db.getDocument(id);
      notifyListeners();
    }
  }

  /// 仅改章节所属分卷（不重排）。
  Future<void> setDocumentVolume(String id, String? volumeId) async {
    await _db.setDocumentVolume(id, volumeId);
    await _reloadTree();
    if (_currentDocument != null && _currentDocument!.id == id) {
      _currentDocument = await _db.getDocument(id);
      notifyListeners();
    }
  }

  /// 复制章节：创建副本并刷新树。
  Future<Document> duplicateDocument(String id) async {
    final doc = await _db.duplicateDocument(id);
    await _reloadTree();
    return doc;
  }

  /// 拆分章节：在纯文本偏移处将文档一分为二，后半段作为新章节插入。
  ///
  /// [splitOffset] 为纯文本中的字符偏移（来自编辑器选区或光标位置）。
  /// 返回新创建的后半段文档。
  Future<Document> splitDocument(String id, int splitOffset) async {
    final src = await _db.getDocument(id);
    if (src == null) throw StateError('文档不存在: $id');
    final result = splitDocumentContent(src.content, splitOffset);
    // 更新原文档为前半段
    await _db.saveDocument(
      id: id,
      title: src.title,
      content: result.firstContent,
      writtenWords: 0,
    );
    // 创建新文档（后半段），position 紧跟原文档
    final newDoc = await _db.createDocument(
      src.notebookId,
      title: '${src.title}（续）',
      content: result.secondContent,
      volumeId: src.volumeId,
    );
    // 把新文档移到原文档之后
    await _db.reorderDocument(
      newDoc.id,
      notebookId: src.notebookId,
      newPosition: src.position + 1,
    );
    await _reloadTree();
    return newDoc;
  }

  /// 合并章节：将 [sourceId] 的内容追加到 [targetId] 末尾，然后删除源文档。
  Future<void> mergeDocuments({
    required String targetId,
    required String sourceId,
  }) async {
    final target = await _db.getDocument(targetId);
    final source = await _db.getDocument(sourceId);
    if (target == null) throw StateError('目标文档不存在: $targetId');
    if (source == null) throw StateError('源文档不存在: $sourceId');
    final merged = mergeDocumentContent(target.content, source.content);
    await _db.saveDocument(
      id: targetId,
      title: target.title,
      content: merged,
      writtenWords: 0,
    );
    await _db.deleteDocument(sourceId);
    await _reloadTree();
    if (_currentDocument?.id == sourceId) {
      await switchDocument(targetId);
    }
  }

  /// 设置章节状态标记。
  Future<void> setDocumentStatus(String id, DocumentStatus status) async {
    await _db.setDocumentStatus(id, status);
    final cur = _currentDocument;
    if (cur != null && cur.id == id) {
      _currentDocument = await _db.getDocument(id);
    }
    await _reloadTree();
  }

  /// 设置章节备注（不进正文导出）。
  Future<void> setDocumentNotes(String id, String notes) async {
    await _db.setDocumentNotes(id, notes);
    final cur = _currentDocument;
    if (cur != null && cur.id == id) {
      _currentDocument = await _db.getDocument(id);
    }
    // 备注不触发整树重载——只更新缓存中的备注字段。
    final docs = _documentsByNotebook[cur?.notebookId ?? ''];
    if (docs != null) {
      final index = docs.indexWhere((d) => d.id == id);
      if (index >= 0 && cur != null) {
        docs[index] = cur;
      }
    }
    notifyListeners();
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
    final vols = <String, List<Volume>>{};
    for (final nb in _notebooks) {
      map[nb.id] = await _db.listDocuments(nb.id);
      vols[nb.id] = await _db.listVolumes(nb.id);
    }
    _documentsByNotebook = map;
    _volumesByNotebook = vols;
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
    session.dispose();
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
