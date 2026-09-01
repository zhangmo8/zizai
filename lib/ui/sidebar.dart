/// 侧边栏：文档树（笔记本 ▸ 章节），CRUD 与排序交互。
///
/// 设计依据：docs/app/ui-sidebar.md（Overall Structure / Interactions /
/// State Variants / Component Tree）、design.md（§5.1 侧边栏、
/// 行操作 hover 浮现、空态引导）、docs/plan/analysis/modules.md（side-002 出口：
/// CRUD 与上移/下移）。
library;

import 'package:flutter/material.dart';

import '../app.dart' show AppColors, appColorsOf;
import '../core/models.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import '../util/chinese.dart' show toChineseNumber;
import '../util/platform.dart';
import 'book_settings.dart';
import 'zz.dart';

enum _EditTarget { document, volume }

class _EditSession {
  const _EditSession({
    this.id,
    required this.target,
    required this.initial,
    this.notebookId,
    this.volumeId,
  });

  /// null 表示新建。
  final String? id;
  final _EditTarget target;
  final String initial;

  /// 文档所属笔记本（document 目标需要）。
  final String? notebookId;

  /// 分卷目标（volume 目标需要）。
  final String? volumeId;
}

/// 树行引用：拖拽重排时把扁平行索引映射回（目标笔记本, 目标位置, 目标分卷）。
///
/// 与 `_buildTree` 的 children 一一对应；笔记本头行标记 isHeader，
/// 全局「新建笔记本」编辑行（树末）notebookId 为 null。手动分卷模式下
/// 卷头行标记 isVolumeHeader、未归卷头标记 isUnassignedHeader，均不可拖。
class TreeRowRef {
  const TreeRowRef({
    this.notebookId,
    this.docId,
    this.isHeader = false,
    this.volumeId,
    this.isVolumeHeader = false,
    this.isUnassignedHeader = false,
  });

  final String? notebookId;
  final String? docId;
  final bool isHeader;

  /// 章节所属分卷 / 卷头行对应的分卷（未归卷头为 null）。
  final String? volumeId;
  final bool isVolumeHeader;
  final bool isUnassignedHeader;
}

/// 拖拽落点映射（纯函数，便于单测）：把 ReorderableListView 的扁平行索引
/// 映射为（目标笔记本 id, 目标位置）；不可落点或同笔记本落点未变返回 null。
///
/// [refs] 与列表 children 一一对应；[oldIndex] 为被拖行，[newIndex] 为
/// onReorderItem 语义（移除被拖行后的插入位，无需再处理移除偏移）。
/// 返回的 position 恒为**数据序**（position ASC 基准）：倒序展示（章节排序
/// 为 desc）时展示序与数据序相反，内部按 `docCount - 展示位` 换算，保证
/// 落库后与用户看到的方向一致。
(String?, int)? reorderTarget(
  List<TreeRowRef> refs,
  int oldIndex,
  int newIndex, {
  bool ascending = true,
}) {
  if (oldIndex < 0 || oldIndex >= refs.length) return null;
  final dragged = refs[oldIndex];
  if (dragged.docId == null) return null; // 仅章节行可拖

  final remaining = List<TreeRowRef>.of(refs)..removeAt(oldIndex);
  final insertAt = newIndex.clamp(0, remaining.length);
  final targetNb = _notebookOfInsertion(remaining, insertAt);
  if (targetNb == null) return null;

  // 目标位置 = 目标笔记本内、插入点之前的章节数。
  var position = 0;
  var docCount = 0;
  for (var i = 0; i < insertAt; i++) {
    final r = remaining[i];
    if (r.notebookId == targetNb && r.docId != null) position++;
  }
  for (final r in remaining) {
    if (r.notebookId == targetNb && r.docId != null) docCount++;
  }
  if (!ascending) {
    // 倒序展示：视觉顶部 = 数据末尾，插入位换算回数据序。
    position = docCount - position;
  }
  if (targetNb == dragged.notebookId) {
    // 同笔记本且落点未变 → 不写库。
    var current = 0;
    for (var i = 0; i < oldIndex; i++) {
      final r = refs[i];
      if (r.notebookId == targetNb && r.docId != null) current++;
    }
    if (!ascending) current = docCount - current;
    if (position == current) return null;
  }
  return (targetNb, position);
}

/// 插入点 [insertAt]（插入到该行之前）所属笔记本。
/// 行是笔记本头 → 上一个分区（前一个笔记本）；否则行自身所属。
String? _notebookOfInsertion(List<TreeRowRef> remaining, int insertAt) {
  if (insertAt < remaining.length && !remaining[insertAt].isHeader) {
    return remaining[insertAt].notebookId;
  }
  for (var i = insertAt - 1; i >= 0; i--) {
    final nb = remaining[i].notebookId;
    if (nb != null) return nb;
  }
  return null;
}

/// 手动分卷模式下的拖拽落点映射（纯函数，便于单测）：把扁平行索引映射为
/// `(目标笔记本, 目标分卷, 卷内序号)`；落点不可用 / 位置未变返回 null。
///
/// 卷头行与未归卷头行是不可拖的「分区边界」：
/// - 落到卷头/未归卷头边界 = 移入该卷**末尾**（与「移动到分卷」菜单一致）；
/// - 落到章节行上方 = 移入该章所在卷的对应序号；
/// - 落到列表末尾/按钮行 = 落入最后一个分区末尾。
/// volumeId = null 表示「未分卷」区。无拖动（newIndex == oldIndex）不写库。
/// 返回的卷内序号恒为**数据序**基准：倒序展示时卷内展示序与数据序相反，
/// 内部按「卷内章节数 - 展示位」换算，保证落库后与用户看到的方向一致。
(String, String?, int)? manualReorderTarget(
  List<TreeRowRef> refs,
  int oldIndex,
  int newIndex, {
  bool ascending = true,
}) {
  if (oldIndex < 0 || oldIndex >= refs.length) return null;
  final dragged = refs[oldIndex];
  if (dragged.docId == null || dragged.notebookId == null) return null;
  final nbId = dragged.notebookId!;
  final remaining = List<TreeRowRef>.of(refs)..removeAt(oldIndex);
  final insertAt = newIndex.clamp(0, remaining.length);

  // 无拖动 → 不写库（避免在卷头边界上误把章节挪到下一卷）。
  if (newIndex == oldIndex) return null;

  // 各分卷章节数（不含被拖行），供「落到卷头 = 移入该卷末尾」计算。
  final counts = <String?, int>{};
  for (final r in remaining) {
    if (r.docId != null) counts[r.volumeId] = (counts[r.volumeId] ?? 0) + 1;
  }

  String? targetVolume;
  var indexInVolume = 0;
  String? currentVolume;
  var sectionCount = 0;
  var found = false;
  for (var i = 0; i < remaining.length; i++) {
    final r = remaining[i];
    if (r.notebookId != nbId) continue;
    if (r.isVolumeHeader || r.isUnassignedHeader) {
      if (i == insertAt) {
        // 落到卷头/未归卷头边界：移入该卷末尾。
        targetVolume = r.isVolumeHeader ? r.volumeId : null;
        indexInVolume = counts[targetVolume] ?? 0;
        found = true;
        break;
      }
      currentVolume = r.isVolumeHeader ? r.volumeId : null;
      sectionCount = 0;
      continue;
    }
    if (r.docId != null) {
      if (i == insertAt) {
        // 落到章节行上方：移入该章所在卷的当前序号。
        targetVolume = currentVolume;
        indexInVolume = sectionCount;
        found = true;
        break;
      }
      sectionCount++;
      continue;
    }
    // 按钮行等不可落点：视作落到当前分区末尾。
    if (i == insertAt) {
      targetVolume = currentVolume;
      indexInVolume = sectionCount;
      found = true;
      break;
    }
  }
  if (!found) {
    // 列表最末：落到最后一个分区末尾。
    targetVolume = currentVolume;
    indexInVolume = sectionCount;
  }
  if (!ascending) {
    // 倒序展示：卷内展示序与数据序相反，插入位换算回数据序。
    indexInVolume = (counts[targetVolume] ?? 0) - indexInVolume;
  }
  // 同卷且位置未变 → 不写库。
  if (targetVolume == dragged.volumeId) {
    var current = _volumeIndexIn(refs, oldIndex);
    if (!ascending) current = (counts[targetVolume] ?? 0) - current;
    if (current == indexInVolume) return null;
  }
  return (nbId, targetVolume, indexInVolume);
}

/// [refs] 中第 [index] 行（章节）在其所属分卷内的序号（同卷章节计数）。
int _volumeIndexIn(List<TreeRowRef> refs, int index) {
  final volume = refs[index].volumeId;
  var count = 0;
  for (var i = 0; i < index; i++) {
    final r = refs[i];
    if (r.docId != null && r.volumeId == volume) count++;
  }
  return count;
}

/// 根据已有章节数量推断新章节默认标题：直接按「整本章节数 + 1」编号。
///
/// 不管现有标题是否含数字（「序章」「楔子」等混合标题也照算），
/// 空笔记本返回「第 1 章」。新增：3 章 → 第 4 章。
String suggestedChapterTitle(List<Document> existingDocs) =>
    '第 ${existingDocs.length + 1} 章';

class Sidebar extends StatefulWidget {
  const Sidebar({
    super.key,
    required this.library,
    required this.settings,
    this.onBack,
    this.onOpenBookSearch,
    this.onOpenWordDist,
  });

  final LibraryController library;
  final SettingsController settings;

  /// 返回笔记本管理页（null = 未接线，如测试；顶栏隐藏返回键）。
  final VoidCallback? onBack;

  /// 全书搜索入口（null = 未接线，如测试；顶栏隐藏搜索按钮）。
  final VoidCallback? onOpenBookSearch;

  /// 章节字数分布入口（null = 未接线，如测试；顶栏隐藏该按钮）。
  final VoidCallback? onOpenWordDist;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  _EditSession? _editing;

  // ── 章节标题筛选（平铺只读视图，见 ui-sidebar.md §章节标题筛选）──
  final TextEditingController _filterController = TextEditingController();
  String _filterQuery = '';

  /// 筛选框绑定的书：切书即清空（筛选态只属于当前书的会话）。
  String? _filterNotebookId;

  /// 最近一次构建的行引用（拖拽落点时把扁平索引映射回位置）。
  List<TreeRowRef> _rowRefs = const [];

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_onLibraryChanged);
    widget.settings.addListener(_onLibraryChanged);
  }

  @override
  void didUpdateWidget(covariant Sidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.removeListener(_onLibraryChanged);
      widget.library.addListener(_onLibraryChanged);
    }
    if (oldWidget.settings != widget.settings) {
      oldWidget.settings.removeListener(_onLibraryChanged);
      widget.settings.addListener(_onLibraryChanged);
    }
  }

  @override
  void dispose() {
    widget.library.removeListener(_onLibraryChanged);
    widget.settings.removeListener(_onLibraryChanged);
    _filterController.dispose();
    super.dispose();
  }

  /// 树数据来自 controller，任何变更都刷新自身（壳层 ListenableBuilder 之外也自洽）。
  void _onLibraryChanged() {
    // 切书清空标题筛选。
    final nbId = widget.library.currentNotebook?.id;
    if (nbId != _filterNotebookId && _filterQuery.isNotEmpty) {
      _filterController.clear();
      _filterQuery = '';
    }
    _filterNotebookId = nbId;
    if (mounted) setState(() {});
  }

  bool _isEditingDocument(String id) =>
      _editing?.target == _EditTarget.document && _editing?.id == id;

  bool _isEditingVolume(String id) =>
      _editing?.target == _EditTarget.volume && _editing?.id == id;

  /// 校验：空名 / 非法字符 / 同名冲突（文档限当前书内；分卷限卷名）。
  String? _validateName(_EditSession session, String value) {
    final name = value.trim();
    if (name.isEmpty) return '名称不能为空';
    if (name.contains('/') || name.contains('\\')) return '名称不能包含 / 或 \\';
    final library = widget.library;
    if (session.target == _EditTarget.volume) {
      final nbId = session.notebookId;
      if (nbId == null) return null;
      final dup = library
          .volumesOf(nbId)
          .any((v) => v.name == name && v.id != session.id);
      return dup ? '同名已存在' : null;
    }
    final dup = library
        .documentsOf(session.notebookId ?? '')
        .any((d) => d.title == name && d.id != session.id);
    return dup ? '同名已存在' : null;
  }

  Future<void> _commitEdit(String rawValue) async {
    final session = _editing;
    if (session == null) return;
    if (_validateName(session, rawValue) != null) return; // 错误态由输入框持有
    final name = rawValue.trim();
    final notebookId = session.notebookId;
    if (notebookId == null) return;
    if (session.target == _EditTarget.volume) {
      if (session.volumeId != null) {
        // 手动分卷：改 volumes 表卷名。
        await widget.library.renameVolume(session.volumeId!, name);
      } else {
        // 自动分卷：改该卷序号的显示名（settings，空串恢复「第 N 卷」）。
        final number = int.tryParse(session.id ?? '') ?? 0;
        if (number > 0) {
          await widget.settings.setAutoVolumeName(notebookId, number, name);
        }
      }
      if (mounted) setState(() => _editing = null);
      return;
    }
    if (session.id == null) {
      await widget.library.createDocument(notebookId, title: name);
    } else {
      await widget.library.renameDocument(session.id!, name);
    }
    if (mounted) setState(() => _editing = null);
  }

  void _cancelEdit() => setState(() => _editing = null);

  void _startEdit(_EditSession session) => setState(() => _editing = session);

  /// 点「+」直接创建章节：suggestedChapterTitle 自动编号（已有 3 章 → 第 4 章），
  /// 不进入命名环节；创建后保持当前文档不变（不打断写作流）。
  /// 手动分卷模式下新章节归入当前卷（当前打开文档所在卷 → 最后一卷 → 无卷时自动建卷）。
  Future<void> _createDocumentDirect(String notebookId) async {
    final title = suggestedChapterTitle(
      widget.library.documentsOf(notebookId),
    );
    final volume = widget.settings.volumeForNotebook(notebookId);
    final grouped = volume.enabled && widget.settings.volumeViewGrouped;
    final volumeId = grouped && volume.mode == VolumeMode.manual
        ? await _targetVolumeForNew(notebookId)
        : null;
    await widget.library.createDocument(
      notebookId,
      title: title,
      volumeId: volumeId,
    );
  }

  /// 手动分卷模式新建章节的归卷目标（非空）：当前打开文档所在卷 → 最后一卷；
  /// 无卷时自动创建一个卷（章节必须有归属，没有「未归卷」）。
  Future<String?> _targetVolumeForNew(String notebookId) async {
    final library = widget.library;
    final cur = library.currentDocument;
    final volumes = library.volumesOf(notebookId);
    if (cur != null &&
        cur.notebookId == notebookId &&
        cur.volumeId != null &&
        volumes.any((v) => v.id == cur.volumeId)) {
      return cur.volumeId;
    }
    if (volumes.isNotEmpty) return volumes.last.id;
    final vol = await library.createVolume(
      notebookId,
      name: '第一卷',
    );
    return vol.id;
  }

  /// 直接新建分卷（默认名「第 N 卷」中文数字），随后可卷头重命名。
  Future<void> _createVolume(String notebookId) async {
    final volumes = widget.library.volumesOf(notebookId);
    await widget.library.createVolume(
      notebookId,
      name: '第${toChineseNumber(volumes.length + 1)}卷',
    );
  }

  /// 删除分卷 = 连卷带卷内所有章节一起删除（无「未归卷」）。
  Future<void> _deleteVolume(Notebook nb, Volume vol) async {
    final count = widget.library
        .documentsOf(nb.id)
        .where((d) => d.volumeId == vol.id)
        .length;
    final confirmed = await zzConfirm(
      context,
      title: '删除分卷「${vol.name}」？',
      message: '卷内 $count 个章节将一并删除，此操作不可恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (confirmed) {
      await widget.library.deleteVolumeWithDocs(
        vol.id,
        documentIds: widget.library
            .documentsOf(nb.id)
            .where((d) => d.volumeId == vol.id)
            .map((d) => d.id)
            .toList(),
      );
    }
  }

  /// 章节「移动到分卷」：目标卷内末尾。
  Future<void> _moveToVolume(
    Document doc, {
    required String volumeId,
  }) async {
    final docs = widget.library.documentsOf(doc.notebookId);
    var count = 0;
    for (final d in docs) {
      if (d.id == doc.id) continue;
      if (d.volumeId == volumeId) count++;
    }
    await widget.library.moveDocumentToVolume(
      doc.id,
      volumeId: volumeId,
      indexInVolume: count,
    );
  }

  /// 打开「针对写作设置」对话框。
  void _openBookSettings() {
    final nb = widget.library.currentNotebook;
    if (nb == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => BookSettingsDialog(
        notebook: nb,
        library: widget.library,
        settings: widget.settings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nb = widget.library.currentNotebook;
    return ColoredBox(
      color: appColorsOf(context).sidebar,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BookHeader(
              title: nb?.name ?? '',
              onBack: widget.onBack,
              onOpenBookSettings: _openBookSettings,
              onOpenBookSearch: widget.onOpenBookSearch,
              onOpenWordDist: widget.onOpenWordDist,
              volumeEnabled:
                  nb != null &&
                  widget.settings.volumeForNotebook(nb.id).enabled,
              volumeViewGrouped: widget.settings.volumeViewGrouped,
              volumeMode:
                  nb != null
                      ? widget.settings.volumeForNotebook(nb.id).mode
                      : VolumeMode.auto,
              onToggleVolumeView: () => widget.settings.setVolumeView(
                widget.settings.volumeViewGrouped ? 'flat' : 'grouped',
              ),
              onCreateVolume: nb == null
                  ? null
                  : () => _createVolume(nb.id),
            ),
            // 章节标题筛选行（有章节的书才显示；平铺只读视图，见 _buildFilteredTree）。
            if (nb != null &&
                !widget.library.loading &&
                widget.library.documentsOf(nb.id).isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: ZzTextField(
                  key: const ValueKey('sidebar-title-filter'),
                  controller: _filterController,
                  hint: '筛选章节标题…',
                  compact: true,
                  onChanged: _onFilterChanged,
                  suffix: _filterQuery.isEmpty
                      ? null
                      : Tooltip(
                          message: '清除筛选',
                          child: InkWell(
                            onTap: () {
                              _filterController.clear();
                              _onFilterChanged('');
                            },
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.cancel,
                                size: 16,
                                color: appColorsOf(context).textTertiary,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            Expanded(
              child: nb == null
                  ? const SizedBox.shrink()
                  : widget.library.loading
                  ? const _LoadingSkeleton()
                  : _buildTree(nb),
            ),
            // 章节列表底部工具行：空书/加载中不显示。
            if (nb != null &&
                !widget.library.loading &&
                widget.library.documentsOf(nb.id).isNotEmpty)
              _TreeFooter(onOpenWordDist: widget.onOpenWordDist),
          ],
        ),
      ),
    );
  }

  /// 筛选词变化（trim 后存态；千章 contains 毫秒级，无需防抖）。
  void _onFilterChanged(String value) =>
      setState(() => _filterQuery = value.trim());

  /// 章节标题筛选（平铺只读视图）：只列标题命中的章节。
  ///
  /// 完全绕开 ReorderableListView 与拖拽 ref——被过滤破坏的顺序视图里
  /// 拖拽语义不明；点击照常跳转，当前章高亮保留，其余交互（新建/拖拽/
  /// 卷头）在筛选态全部隐藏。
  Widget _buildFilteredTree(Notebook nb, String query) {
    final needle = query.toLowerCase();
    final matches = [
      for (final doc in widget.library.documentsOf(nb.id))
        if (doc.title.toLowerCase().contains(needle)) doc,
    ];
    if (matches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '没有匹配「$query」的章节',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: appColorsOf(context).textTertiary,
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 18),
      itemCount: matches.length,
      itemBuilder: (context, i) =>
          _documentRow(nb, matches[i], i, draggable: false),
    );
  }

  /// 单书章节树。
  /// - 分卷关闭 / 视图「平铺展示」→ 平铺章节列表。
  /// - 自动分卷 → 按每卷章数插入「第 N 卷」分组标题（纯推导，不写库，可重命名）；
  ///   分组按数据序固定，倒序只反转卷序与卷内章节，卷名不随排序漂移。
  /// - 手动分卷 → 按 volumes 表真实分组；卷头可新建/重命名/删除，章节可移动。
  /// - 章节排序（设置 → 目录 → 章节排序）：倒序时最新章在上，
  ///   「+ 新建章节」按钮随「序列末尾端」移动（正序在最下，倒序在最上）。
  Widget _buildTree(Notebook nb) {
    // 标题筛选态：平铺只读分支，完全绕开拖拽与新建（顺序视图被过滤破坏）。
    final filterQuery = _filterQuery;
    if (filterQuery.isNotEmpty) return _buildFilteredTree(nb, filterQuery);
    final library = widget.library;
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final children = <Widget>[];
    final refs = <TreeRowRef>[];

    void add(Widget child, TreeRowRef ref) {
      children.add(child);
      refs.add(ref);
    }

    final ascending = widget.settings.docsAscending(nb.id);
    final docs = library.documentsOf(nb.id);
    final orderedDocs = ascending ? docs : docs.reversed.toList();
    final volume = widget.settings.volumeForNotebook(nb.id);
    final grouped = volume.enabled && widget.settings.volumeViewGrouped;
    final manual = grouped && volume.mode == VolumeMode.manual;
    final volumes = library.volumesOf(nb.id);

    // 「+ 新建章节」跟随序列末尾端：正序在树末，倒序在树顶（与最新章节相邻）。
    // 倒序时**先插入**——章节行的列表下标必须与 children 实际位置一致
    // （拖拽 listener 依赖 index，后插到 0 位会让所有章节行的 index 错位一位）。
    if (!ascending && docs.isNotEmpty) {
      _addNewDocButton(nb, add);
    }

    if (manual) {
      _buildManualTree(nb, orderedDocs, volumes, add, indexOf: () => children.length);
    } else {
      // 自动分卷：分组按**数据序**推导（第 N 卷 = 数据序第 N 组），与排序方向
      // 无关；倒序时卷序与卷内章节都反转（与手动分卷语义一致），卷名与
      // 章节归属不随排序方向漂移。平铺视图视为单个大卷、不插卷头。
      final chunks = <List<Document>>[];
      if (grouped) {
        for (var i = 0; i < docs.length; i += volume.chapters) {
          final end = (i + volume.chapters).clamp(0, docs.length);
          chunks.add(docs.sublist(i, end));
        }
      } else if (docs.isNotEmpty) {
        chunks.add(docs);
      }
      final orderedChunks = ascending ? chunks : chunks.reversed.toList();
      for (var ci = 0; ci < orderedChunks.length; ci++) {
        final chunk = orderedChunks[ci];
        if (grouped) {
          // 卷序号按数据序固定：倒序展示时最后一个数据块（最新章）在最上。
          final number = ascending ? ci + 1 : chunks.length - ci;
          if (_isEditingVolume('$number')) {
            add(
              _editField(
                _editing!,
                '$number',
                notebookId: nb.id,
                key: ValueKey('edit-vol-auto-$number'),
              ),
              TreeRowRef(notebookId: nb.id, isHeader: true),
            );
          } else {
            add(
              _VolumeHeader(
                key: ValueKey('vol-${nb.id}-$number'),
                title: widget.settings.autoVolumeName(nb.id, number),
                count: '${chunk.length} 章',
                menuItems: [
                  _MenuEntry(
                    '重命名',
                    Icons.drive_file_rename_outline,
                    action: () => _startEdit(
                      _EditSession(
                        id: '$number',
                        target: _EditTarget.volume,
                        initial: widget.settings.autoVolumeName(
                          nb.id,
                          number,
                        ),
                        notebookId: nb.id,
                      ),
                    ),
                  ),
                ],
              ),
              TreeRowRef(notebookId: nb.id, isHeader: true),
            );
          }
        }
        final chunkDocs = ascending ? chunk : chunk.reversed.toList();
        for (final doc in chunkDocs) {
          if (_isEditingDocument(doc.id)) {
            add(
              _editField(
                _editing!,
                doc.id,
                notebookId: nb.id,
                key: ValueKey('edit-doc-${doc.id}'),
              ),
              TreeRowRef(notebookId: nb.id, docId: doc.id),
            );
          } else {
            final index = children.length;
            add(
              _documentRow(nb, doc, index),
              TreeRowRef(notebookId: nb.id, docId: doc.id),
            );
          }
        }
      }
    }

    // 「+ 新建章节」跟随序列末尾端：正序在树末（倒序已在树顶先行插入）。
    if (ascending && docs.isNotEmpty) {
      _addNewDocButton(nb, add);
    }
    _rowRefs = refs;

    if (docs.isEmpty) {
      return _ChapterEmptyState(
        onCreate: () => _createDocumentDirect(nb.id),
      );
    }

    return ReorderableListView(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 18),
      onReorderItem: _onReorderItem,
      proxyDecorator: (child, index, animation) =>
          _dragProxyDecorator(child, animation, colors, appColors),
      children: children,
    );
  }

  /// 「+ 新建章节」行：正序插树末、倒序插树顶共用同一接线。
  void _addNewDocButton(
    Notebook nb,
    void Function(Widget child, TreeRowRef ref) add,
  ) {
    add(
      _NewDocumentButton(
        key: ValueKey('new-doc-${nb.id}'),
        onPressed: () => _createDocumentDirect(nb.id),
      ),
      TreeRowRef(notebookId: nb.id),
    );
  }

  /// 手动分卷树：卷序 → 卷内章节。
  /// 无「未归卷」概念——章节永远属于某卷（新章节自动落卷；脏数据卷 id 回退最后一卷）。
  /// 排序：倒序时卷与卷内章节都反转（最后一卷、最新章在最上）。
  /// [indexOf] 返回「下一个章节行的列表下标」（children 当前长度），
  /// 供拖拽 listener 使用——必须与 ReorderableListView 的实际位置一致。
  void _buildManualTree(
    Notebook nb,
    List<Document> docs,
    List<Volume> volumes,
    void Function(Widget child, TreeRowRef ref) add, {
    required int Function() indexOf,
  }) {
    // 分桶：卷序 → 章节（docs 已按展示序传入，桶内保持该顺序）。
    final buckets = <String, List<Document>>{
      for (final vol in volumes) vol.id: <Document>[],
    };
    // 兜底桶：无任何卷但残留章节（如旧版删卷只清归属、卷全删光后遗留的脏数据），
    // 平铺渲染不崩溃；用户建卷后用「移动到分卷」归章。
    final orphan = <Document>[];
    for (final doc in docs) {
      if (volumes.isNotEmpty && buckets.containsKey(doc.volumeId)) {
        buckets[doc.volumeId!]!.add(doc);
      } else if (volumes.isNotEmpty) {
        buckets[volumes.last.id]!.add(doc); // 脏数据（指向已删卷）→ 最后一卷
      } else {
        orphan.add(doc);
      }
    }
    final ascending = widget.settings.docsAscending(nb.id);
    final orderedVolumes = ascending ? volumes : volumes.reversed.toList();

    for (final vol in orderedVolumes) {
      final bucket = buckets[vol.id] ?? const <Document>[];
      if (_isEditingVolume(vol.id)) {
        add(
          _editField(
            _editing!,
            vol.id,
            notebookId: nb.id,
            key: ValueKey('edit-vol-${vol.id}'),
          ),
          TreeRowRef(
            notebookId: nb.id,
            isVolumeHeader: true,
            volumeId: vol.id,
          ),
        );
      } else {
        add(
          _VolumeHeader(
            key: ValueKey('vol-${vol.id}'),
            title: vol.name,
            count: '${bucket.length} 章',
            manual: true,
            menuItems: [
              _MenuEntry(
                '重命名',
                Icons.drive_file_rename_outline,
                action: () => _startEdit(
                  _EditSession(
                    id: vol.id,
                    target: _EditTarget.volume,
                    initial: vol.name,
                    notebookId: nb.id,
                    volumeId: vol.id,
                  ),
                ),
              ),
              _MenuEntry(
                '删除卷',
                Icons.delete_outline,
                action: () => _deleteVolume(nb, vol),
              ),
            ],
          ),
          TreeRowRef(
            notebookId: nb.id,
            isVolumeHeader: true,
            volumeId: vol.id,
          ),
        );
      }
      for (final doc in bucket) {
        _addManualDocRow(nb, doc, add, indexOf);
      }
    }
    // 兜底：无卷残留章节平铺在卷列表末尾（不崩溃，建卷后可用「移动到分卷」归章）。
    for (final doc in orphan) {
      _addManualDocRow(nb, doc, add, indexOf);
    }
  }

  void _addManualDocRow(
    Notebook nb,
    Document doc,
    void Function(Widget child, TreeRowRef ref) add,
    int Function() indexOf,
  ) {
    if (_isEditingDocument(doc.id)) {
      add(
        _editField(
          _editing!,
          doc.id,
          notebookId: nb.id,
          key: ValueKey('edit-doc-${doc.id}'),
        ),
        TreeRowRef(notebookId: nb.id, docId: doc.id, volumeId: doc.volumeId),
      );
      return;
    }
    add(
      _documentRow(nb, doc, indexOf()),
      TreeRowRef(notebookId: nb.id, docId: doc.id, volumeId: doc.volumeId),
    );
  }

  /// 章节行 + 拖拽接线：桌面端仅手柄可拖（行体点击不受干扰），
  /// 触摸端整行长按拖拽（短按仍是切换文档）。
  Widget _documentRow(
    Notebook nb,
    Document doc,
    int index, {
    bool draggable = true,
  }) {
    final library = widget.library;
    final volume = widget.settings.volumeForNotebook(nb.id);
    final grouped = volume.enabled && widget.settings.volumeViewGrouped;
    final manual = grouped && volume.mode == VolumeMode.manual;
    // 手动分卷：章节菜单加「移动到分卷」二级菜单（列出所有卷）。
    final moveItems = manual
        ? <({String label, VoidCallback action})>[
            for (final v in library.volumesOf(nb.id))
              (
                label: v.name,
                action: () => _moveToVolume(doc, volumeId: v.id),
              ),
          ]
        : null;
    final tile = _DocumentTile(
      key: ValueKey('doc-${doc.id}'),
      index: index,
      draggable: draggable,
      document: doc,
      selected: library.currentDocument?.id == doc.id,
      onTap: () => library.switchDocument(doc.id),
      onEdit: () => _startEdit(
        _EditSession(
          id: doc.id,
          target: _EditTarget.document,
          initial: doc.title,
          notebookId: nb.id,
        ),
      ),
      onDelete: () => library.requestDelete(
        kind: DeletionKind.document,
        id: doc.id,
        name: doc.title,
      ),
      // 章节排序方向：正序时「上移」= 数据上移；倒序时展示上移 = 数据下移。
      onMoveUp: () =>
          library.moveDocument(doc.id, up: widget.settings.docsAscending(nb.id)),
      onMoveDown: () => library.moveDocument(
        doc.id,
        up: !widget.settings.docsAscending(nb.id),
      ),
      moveVolumeItems: moveItems,
    );
    if (!isDesktopPlatform && draggable) {
      // ReorderableListView 要求顶层 child 必须有 key：release 下缺 key
      // 不报 assert，而是列表变化（新建/删除）时 element diff 错位 →
      // Android Drawer 整块白屏（真机回归）。key 与章节行一致。
      return ReorderableDelayedDragStartListener(
        key: ValueKey('doc-${doc.id}'),
        index: index,
        child: tile,
      );
    }
    return tile;
  }

  /// 拖拽落点：自动/平铺 →（目标笔记本, 位置）；手动 →（目标笔记本, 分卷, 卷内位）。
  ///
  /// onReorderItem 语义：newIndex 是「移除拖拽行之后」的插入位（已调整）。
  void _onReorderItem(int oldIndex, int newIndex) {
    final refs = _rowRefs;
    final docId = refs[oldIndex].docId;
    if (docId == null) return;
    final nbId = widget.library.currentNotebook?.id;
    final volume = widget.settings.volumeForNotebook(nbId);
    final grouped = volume.enabled && widget.settings.volumeViewGrouped;
    final ascending = widget.settings.docsAscending(nbId);
    if (grouped && volume.mode == VolumeMode.manual) {
      final target = manualReorderTarget(
        refs,
        oldIndex,
        newIndex,
        ascending: ascending,
      );
      if (target == null) return;
      final (targetNb, volumeId, indexInVolume) = target;
      widget.library.moveDocumentToVolume(
        docId,
        volumeId: volumeId,
        indexInVolume: indexInVolume,
      );
      return;
    }
    final target = reorderTarget(refs, oldIndex, newIndex, ascending: ascending);
    if (target == null) return;
    final (targetNb, position) = target;
    widget.library.reorderDocument(
      docId,
      notebookId: targetNb!, // reorderTarget 非 null 返回时 targetNb 必非 null
      newPosition: position,
    );
  }

  /// 拖拽浮层：design.md §3 浮层阴影（0 4px 12px 10% 黑 + 1px hairline 描边）。
  Widget _dragProxyDecorator(
    Widget child,
    Animation<double> animation,
    ColorScheme colors,
    AppColors appColors,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = Curves.easeOut.transform(animation.value);
        return Opacity(
          opacity: 0.9 + 0.1 * t,
          child: Transform.scale(
            scale: 0.985 + 0.015 * t,
            child: Material(
              type: MaterialType.transparency,
              elevation: 0,
              child: Container(
                decoration: BoxDecoration(
                  color: appColors.surfaceRaised,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colors.outline),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _editField(
    _EditSession session,
    String? id, {
    String? notebookId,
    Key? key,
  }) {
    final resolved = _EditSession(
      id: id,
      target: session.target,
      initial: session.initial,
      notebookId: notebookId ?? session.notebookId,
    );
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(34, 2, 4, 2),
      child: _InlineEditField(
        key: ValueKey('edit-${resolved.target}-${resolved.id ?? 'new'}'),
        initial: resolved.initial,
        validate: (v) => _validateName(resolved, v),
        onSubmit: _commitEdit,
        onCancel: _cancelEdit,
      ),
    );
  }
}

/// 单书工作区顶栏：返回 + 书名 + 新建分卷 + 分卷视图切换 + 全书搜索 + 本书设置。
class _BookHeader extends StatelessWidget {
  const _BookHeader({
    required this.title,
    this.onBack,
    this.onOpenBookSettings,
    this.onOpenBookSearch,
    this.onOpenWordDist,
    this.volumeEnabled = false,
    this.volumeViewGrouped = true,
    this.volumeMode = VolumeMode.auto,
    this.onToggleVolumeView,
    this.onCreateVolume,
  });

  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onOpenBookSettings;
  final VoidCallback? onOpenBookSearch;

  /// 章节字数分布入口（null = 未接线；顶栏隐藏该按钮）。
  final VoidCallback? onOpenWordDist;

  /// 分卷是否开启（开启才显示「分卷展示/平铺展示」切换与「新建分卷」）。
  final bool volumeEnabled;

  /// 当前目录视图：true = 分卷展示，false = 平铺展示。
  final bool volumeViewGrouped;

  /// 分卷方式（手动分卷、分卷展示时显示「+ 新建分卷」）。
  final VolumeMode volumeMode;
  final VoidCallback? onToggleVolumeView;
  final VoidCallback? onCreateVolume;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 8, 6),
      child: Row(
        children: [
          if (onBack != null)
            ZzIconButton(
              tooltip: '返回笔记本管理',
              icon: Icons.arrow_back,
              onPressed: onBack!,
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
            ),
          ),
          if (volumeEnabled &&
              volumeMode == VolumeMode.manual &&
              volumeViewGrouped &&
              onCreateVolume != null)
            ZzIconButton(
              tooltip: '新建分卷',
              icon: Icons.create_new_folder_outlined,
              onPressed: onCreateVolume!,
            ),
          if (volumeEnabled && onToggleVolumeView != null)
            ZzIconButton(
              tooltip: volumeViewGrouped ? '平铺展示' : '分卷展示',
              icon: volumeViewGrouped
                  ? Icons.account_tree_outlined
                  : Icons.view_agenda_outlined,
              onPressed: onToggleVolumeView!,
            ),
          if (onOpenBookSearch != null)
            ZzIconButton(
              tooltip: '全书搜索 (${isMacOS ? '⌘' : 'Ctrl'}+P)',
              icon: Icons.search,
              onPressed: onOpenBookSearch!,
            ),
          if (onOpenBookSettings != null)
            ZzIconButton(
              tooltip: '写作设置',
              icon: Icons.settings_outlined,
              onPressed: onOpenBookSettings!,
            ),
        ],
      ),
    );
  }
}

/// 章节列表底部工具行：安静的查看类入口（字数分布等），右对齐小 icon。
class _TreeFooter extends StatelessWidget {
  const _TreeFooter({this.onOpenWordDist});

  final VoidCallback? onOpenWordDist;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      child: Row(
        children: [
          const Spacer(),
          if (onOpenWordDist != null)
            ZzIconButton(
              tooltip: '章节字数分布',
              icon: Icons.bar_chart,
              onPressed: onOpenWordDist!,
            ),
        ],
      ),
    );
  }
}

/// 分卷分组标题（目录里的卷行）。
///
/// - 自动分卷：卷头为推导分组，菜单仅「重命名」（自定义名存 settings）。
/// - 手动分卷：卷头为真数据卷，菜单「重命名 / 删除卷」。
class _VolumeHeader extends StatefulWidget {
  const _VolumeHeader({
    super.key,
    required this.title,
    this.count,
    this.manual = false,
    this.menuItems = const [],
  });

  final String title;

  /// 章数角标（如「12 章」）；null 不显示。
  final String? count;

  /// 手动分卷（真数据卷，删除可交互）；自动分卷卷头视觉略轻。
  final bool manual;

  final List<_MenuEntry> menuItems;

  @override
  State<_VolumeHeader> createState() => _VolumeHeaderState();
}

class _VolumeHeaderState extends State<_VolumeHeader> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        height: 30,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.only(left: 10, right: 4),
        decoration: BoxDecoration(
          color: _hover ? appColors.surfaceHover : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Icon(
              widget.manual ? Icons.menu_book_outlined : Icons.folder_outlined,
              size: 15,
              color: appColors.textTertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            if (widget.count != null)
              Text(
                widget.count!,
                style: TextStyle(fontSize: 11, color: appColors.textTertiary),
              ),
            if (widget.menuItems.isNotEmpty)
              _RowMenu(
                visible: _hover || !isDesktopPlatform,
                items: widget.menuItems,
              ),
          ],
        ),
      ),
    );
  }
}

/// 空章节引导（单书工作区）。
class _ChapterEmptyState extends StatelessWidget {
  const _ChapterEmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description_outlined,
                size: 32, color: appColors.textTertiary),
            const SizedBox(height: 8),
            Text(
              '这本书还没有章节',
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            ZzButton.primary(label: '新建第一章', onPressed: onCreate),
          ],
        ),
      ),
    );
  }
}

/// 文档行：选中高亮 + ⋮ 操作菜单（桌面端 hover 行才浮现）。
class _DocumentTile extends StatefulWidget {
  const _DocumentTile({
    super.key,
    required this.index,
    required this.document,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
    this.moveVolumeItems,
    this.draggable = true,
  });

  /// 在 ReorderableListView 中的行索引（拖拽手柄定位用）。
  final int index;
  final Document document;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  /// 手动分卷模式：章节菜单里的「移动到分卷」二级菜单项（卷 + 未分卷）。
  final List<({String label, VoidCallback action})>? moveVolumeItems;

  /// false = 不可拖拽（标题筛选态）：不渲染拖拽手柄，不包装拖拽 listener。
  final bool draggable;

  @override
  State<_DocumentTile> createState() => _DocumentTileState();
}

class _DocumentTileState extends State<_DocumentTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: _SidebarRow(
        depth: 1,
        hover: _hover,
        selected: widget.selected,
        onTap: widget.onTap,
        leading: _buildLeading(colors),
        title: widget.document.title,
        titleStyle: TextStyle(
          fontSize: 13,
          fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
          color: widget.selected ? colors.onSurface : colors.onSurfaceVariant,
        ),
        trailing: _RowMenu(
          visible: _hover || !isDesktopPlatform,
          items: [
            _MenuEntry('上移', Icons.arrow_upward, action: widget.onMoveUp),
            _MenuEntry('下移', Icons.arrow_downward, action: widget.onMoveDown),
            // 仅手动分卷出现「移动到分卷」（自动分卷为纯推导，无真卷可移动）。
            if (widget.moveVolumeItems != null)
              _MenuEntry(
                '移动到分卷',
                Icons.drive_file_move_outline,
                submenu: widget.moveVolumeItems,
              ),
            _MenuEntry(
              '重命名',
              Icons.drive_file_rename_outline,
              action: widget.onEdit,
            ),
            _MenuEntry('删除', Icons.delete_outline, action: widget.onDelete),
          ],
        ),
      ),
    );
  }

  /// 章节行前置图标：平时是章节 icon，桌面端 hover 时切换为拖拽手柄。
  ///
  /// 手柄用 Stack 常驻树中（opacity/IgnorePointer 切换）：既保持低打扰的
  /// 图标态，又让拖拽起点固定在最前（不随内容宽度漂移）。点击手柄由空
  /// onTap 消费，避免 pan 未确认时落到行体切换文档。
  Widget _buildLeading(ColorScheme colors) {
    final iconColor = widget.selected ? colors.onSurface : colors.onSurfaceVariant;
    final chapterIcon = Icon(
      Icons.description_outlined,
      size: 15,
      color: iconColor,
    );
    if (!isDesktopPlatform || !widget.draggable) return chapterIcon; // 触摸端整行长按拖拽，无需手柄
    return SizedBox(
      width: 18,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 90),
            opacity: _hover ? 0 : 1,
            child: chapterIcon,
          ),
          IgnorePointer(
            ignoring: !_hover,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 90),
              opacity: _hover ? 1 : 0,
              child: ReorderableDragStartListener(
                index: widget.index,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: Icon(
                    Icons.drag_indicator,
                    size: 15,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.depth,
    required this.hover,
    required this.selected,
    required this.onTap,
    required this.leading,
    required this.title,
    required this.titleStyle,
    this.trailing,
  });

  final int depth;
  final bool hover;
  final bool selected;
  final VoidCallback onTap;
  final Widget leading;
  final String title;
  final TextStyle titleStyle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final appColors = appColorsOf(context);
    final bg = selected
        ? appColors.rowSelected
        : hover
        ? appColors.surfaceHover
        : Colors.transparent;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      height: 30,
      margin: const EdgeInsets.symmetric(vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.only(left: 6 + depth * 22, right: 2),
          child: Row(
            children: [
              SizedBox(width: depth == 0 ? 38 : 18, child: leading),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// 行内编辑输入框：Enter 确认 / Esc 取消，错误态不允许提交。
class _InlineEditField extends StatefulWidget {
  const _InlineEditField({
    super.key,
    required this.initial,
    required this.validate,
    required this.onSubmit,
    required this.onCancel,
  });

  final String initial;
  final String? Function(String value) validate;
  final Future<void> Function(String value) onSubmit;
  final VoidCallback onCancel;

  @override
  State<_InlineEditField> createState() => _InlineEditFieldState();
}

class _InlineEditFieldState extends State<_InlineEditField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _submitting = false;

  Future<void> _submit() async {
    if (_submitting) return;
    final error = widget.validate(_controller.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    await widget.onSubmit(_controller.text);
    if (mounted) setState(() => _submitting = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return EscapeFocus(
      onEscape: widget.onCancel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: ZzTextField(
                  key: const ValueKey('inline-edit-field'),
                  controller: _controller,
                  hint: '',
                  autofocus: true,
                  compact: true,
                  enabled: !_submitting,
                  error: _error != null,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 4),
              _InlineEditAction(
                tooltip: '取消编辑',
                icon: Icons.close,
                color: colors.onSurfaceVariant,
                onPressed: _submitting ? null : widget.onCancel,
              ),
              const SizedBox(width: 2),
              _InlineEditAction(
                tooltip: '保存名称',
                icon: _submitting ? Icons.more_horiz : Icons.check,
                color: colors.primary,
                onPressed: _submitting ? null : _submit,
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 8),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 11, color: colors.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _InlineEditAction extends StatelessWidget {
  const _InlineEditAction({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      color: color,
      disabledColor: color.withValues(alpha: 0.35),
    );
  }
}

/// 行操作 ⋯ 菜单：桌面端由行 hover 控制显隐（低打扰 chrome），触摸端常显。
/// 菜单项：普通动作，或带二级子菜单（如「移动到分卷」→ 卷列表）。
class _MenuEntry {
  const _MenuEntry(
    this.label,
    this.icon, {
    this.action,
    this.submenu,
  });

  final String label;
  final IconData icon;
  final VoidCallback? action;

  /// 二级子菜单（非空时忽略 [action]）；元素 (label, action)。
  final List<({String label, VoidCallback action})>? submenu;
}

/// 行尾 ⋮ 菜单：支持普通动作与二级子菜单（子菜单同锚点二次弹出）。
class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.visible, required this.items});

  final bool visible;
  final List<_MenuEntry> items;

  bool _isDanger(String label) => label == '删除' || label == '删除卷';

  Future<void> _open(BuildContext context) async {
    final colors = Theme.of(context).colorScheme;
    final anchorRect = zzAnchorMenuRect(context, gap: 2);
    final picked = await showMenu<_MenuEntry>(
      context: context,
      position: anchorRect,
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 240),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      items: [
        for (final item in items)
          PopupMenuItem<_MenuEntry>(
            value: item,
            height: 34,
            child: Row(
              children: [
                Icon(
                  item.icon,
                  size: 15,
                  color: _isDanger(item.label)
                      ? colors.error
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _isDanger(item.label)
                        ? TextStyle(color: colors.error)
                        : null,
                  ),
                ),
                if (item.submenu != null)
                  Icon(
                    Icons.chevron_right,
                    size: 15,
                    color: colors.onSurfaceVariant,
                  ),
              ],
            ),
          ),
      ],
    );
    if (picked == null) return;
    if (!context.mounted) return;
    final sub = picked.submenu;
    if (sub == null) {
      picked.action?.call();
      return;
    }
    // 二级菜单：同锚点弹出卷列表。
    final chosen = await showMenu<String>(
      context: context,
      position: anchorRect,
      constraints: const BoxConstraints(minWidth: 140, maxWidth: 220),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      items: [
        for (final s in sub)
          PopupMenuItem<String>(
            key: ValueKey('move-vol-${s.label}'),
            value: s.label,
            height: 32,
            child: Row(
              children: [
                const Icon(Icons.menu_book_outlined, size: 15),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    s.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (chosen == null) return;
    for (final s in sub) {
      if (s.label == chosen) s.action();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 90),
      opacity: visible ? 1 : 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: Tooltip(
          message: '操作',
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => _open(context),
            child: Icon(
              Icons.more_horiz,
              size: 16,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// 展开笔记本底部的「+ 新建章节」。
class _NewDocumentButton extends StatefulWidget {
  const _NewDocumentButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_NewDocumentButton> createState() => _NewDocumentButtonState();
}

class _NewDocumentButtonState extends State<_NewDocumentButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        height: 30,
        margin: const EdgeInsets.symmetric(vertical: 1),
        decoration: BoxDecoration(
          color: _hover ? appColors.surfaceHover : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: widget.onPressed,
          child: Padding(
            padding: const EdgeInsets.only(left: 34, right: 8),
            child: Row(
              children: [
                Icon(Icons.add, size: 15, color: appColors.textTertiary),
                const SizedBox(width: 8),
                Text(
                  '新建章节',
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

/// 加载骨架行 ×3。
class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 4; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Container(
                height: 11,
                width: 96 + i * 28.0,
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

