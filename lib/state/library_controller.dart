/// 库状态：目录树、当前文档、未保存缓冲、今日增量。
///
/// 设计依据：docs/app/README.md §6（状态流：library_controller 是状态所有者）、
/// docs/app/ui-shell.md（State Variants：启动加载 / 空库 / 存储错误）。
library;

import 'package:flutter/foundation.dart';

import '../core/db.dart';
import '../core/models.dart';

class LibraryController extends ChangeNotifier {
  LibraryController(this._db);

  final Db _db;

  List<Notebook> _notebooks = const [];
  List<Notebook> get notebooks => _notebooks;

  Document? _currentDocument;
  Document? get currentDocument => _currentDocument;

  int _todayDelta = 0;
  int get todayDelta => _todayDelta;

  bool _loading = true;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  /// edit-003 注入：切换文档 / 退出前先保存当前缓冲（防丢）。
  Future<void> Function()? beforeSwitchSave;

  /// 启动恢复：目录树 + 今日增量 + 按 last_open 打开上次文档。
  Future<void> restore() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _notebooks = await _db.listNotebooks();
      _todayDelta = await _db.todayDelta();
      final lastOpen = await _db.loadLastOpen();
      if (lastOpen?.documentId != null) {
        _currentDocument = await _db.getDocument(lastOpen!.documentId!);
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
    notifyListeners();
  }

  /// 保存当前文档（edit-003 自动保存调用）：返回字数增量并刷新今日增量/快照。
  Future<int> saveCurrentDocument({required String title, required String content}) async {
    final doc = _currentDocument;
    if (doc == null) {
      throw StateError('无当前文档可保存');
    }
    final delta = await _db.saveDocument(id: doc.id, title: title, content: content);
    _todayDelta = await _db.todayDelta();
    _currentDocument = await _db.getDocument(doc.id);
    notifyListeners();
    return delta;
  }

  /// 新建笔记本（壳空态引导用；完整 CRUD 归 side-002）。
  Future<Notebook> createNotebook(String name) async {
    final nb = await _db.createNotebook(name);
    _notebooks = [..._notebooks, nb];
    notifyListeners();
    return nb;
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
