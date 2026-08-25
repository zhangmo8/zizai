/// 侧边栏：文档树（笔记本 ▸ 章节），CRUD 与排序交互。
///
/// 设计依据：docs/app/ui-sidebar.md（Overall Structure / Interactions /
/// State Variants / Component Tree）、design.md（§5.1 侧边栏、
/// 行操作 hover 浮现、空态引导）、docs/plan/analysis/modules.md（side-002 出口：
/// CRUD 与上移/下移）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart' show AppColors, appColorsOf;
import '../core/models.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import '../util/platform.dart';
import 'book_settings.dart';
import 'zz.dart';

enum _EditTarget { document }

class _EditSession {
  const _EditSession({
    this.id,
    required this.target,
    required this.initial,
    this.notebookId,
  });

  /// null 表示新建。
  final String? id;
  final _EditTarget target;
  final String initial;

  /// 文档所属笔记本（document 目标需要）。
  final String? notebookId;
}

/// 树行引用：拖拽重排时把扁平行索引映射回（目标笔记本, 目标位置）。
///
/// 与 `_buildTree` 的 children 一一对应；笔记本头行标记 isHeader，
/// 全局「新建笔记本」编辑行（树末）notebookId 为 null。
class TreeRowRef {
  const TreeRowRef({this.notebookId, this.docId, this.isHeader = false});

  final String? notebookId;
  final String? docId;
  final bool isHeader;
}

/// 拖拽落点映射（纯函数，便于单测）：把 ReorderableListView 的扁平行索引
/// 映射为（目标笔记本 id, 目标位置）；不可落点或同笔记本落点未变返回 null。
///
/// [refs] 与列表 children 一一对应；[oldIndex] 为被拖行，[newIndex] 为
/// onReorderItem 语义（移除被拖行后的插入位，无需再处理移除偏移）。
(String?, int)? reorderTarget(List<TreeRowRef> refs, int oldIndex, int newIndex) {
  if (oldIndex < 0 || oldIndex >= refs.length) return null;
  final dragged = refs[oldIndex];
  if (dragged.docId == null) return null; // 仅章节行可拖

  final remaining = List<TreeRowRef>.of(refs)..removeAt(oldIndex);
  final insertAt = newIndex.clamp(0, remaining.length);
  final targetNb = _notebookOfInsertion(remaining, insertAt);
  if (targetNb == null) return null;

  // 目标位置 = 目标笔记本内、插入点之前的章节数。
  var position = 0;
  for (var i = 0; i < insertAt; i++) {
    final r = remaining[i];
    if (r.notebookId == targetNb && r.docId != null) position++;
  }
  if (targetNb == dragged.notebookId) {
    // 同笔记本且落点未变 → 不写库。
    var current = 0;
    for (var i = 0; i < oldIndex; i++) {
      final r = refs[i];
      if (r.notebookId == targetNb && r.docId != null) current++;
    }
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

/// 「第 N 章/回/节/卷」式编号标题检测（与 export.dart 的 `_numberedTitle` 同源）。
final RegExp _numberedChapterTitle = RegExp(
  r'^\s*第\s*[0-9０-９一二三四五六七八九十百千万零两]+\s*[章回节卷]',
);

/// 从「第 N 章」式标题中抽取 (序号, 是否阿拉伯数字)；无法解析返回 null。
final RegExp _chapterNumber = RegExp(
  r'第\s*([0-9０-９一二三四五六七八九十百千万零两]+)\s*[章回节卷]',
);
final RegExp _arabicDigits = RegExp(r'^[0-9０-９]+$');

(int, bool)? _chapterNumberOf(String title) {
  final m = _chapterNumber.firstMatch(title);
  if (m == null) return null;
  final raw = m.group(1)!;
  if (_arabicDigits.hasMatch(raw)) {
    final n = int.tryParse(_toHalfWidthDigits(raw));
    return n == null ? null : (n, true);
  }
  final n = _parseChineseNumber(raw);
  return n < 0 ? null : (n, false);
}

/// 根据已有章节推断新章节默认标题。
///
/// 已有章节均符合「第 N 章」模式时按最大序号 +1 自动递增，并沿用原数字
/// 风格（纯中文 → 中文，纯阿拉伯/混用 → 阿拉伯）；任意章节不符合模式则
/// 返回 '新章节'，不强制编号。空笔记本返回 '第 1 章'。
String suggestedChapterTitle(List<Document> existingDocs) {
  if (existingDocs.isEmpty) return '第 1 章';
  // 任意章节不符合编号模式 → 不强制编号，沿用默认名。
  if (!existingDocs.every((d) => _numberedChapterTitle.hasMatch(d.title))) {
    return '新章节';
  }
  var maxNumber = 0;
  var allChinese = true;
  for (final doc in existingDocs) {
    final parsed = _chapterNumberOf(doc.title);
    if (parsed == null) {
      // 全部命中模式但有不可解析序号 → 回退为序号计数 +1。
      return '第 ${existingDocs.length + 1} 章';
    }
    final (n, isArabic) = parsed;
    if (isArabic) allChinese = false;
    if (n > maxNumber) maxNumber = n;
  }
  final next = maxNumber + 1;
  return allChinese ? '第${_toChineseNumber(next)}章' : '第 $next 章';
}

/// 全角数字 ０-９ → 半角 0-9。
String _toHalfWidthDigits(String s) {
  final buf = StringBuffer();
  for (final ch in s.runes) {
    buf.writeCharCode(ch >= 0xFF10 && ch <= 0xFF19 ? ch - 0xFEE0 : ch);
  }
  return buf.toString();
}

/// 中文数字串 → int；无法解析返回 -1。
int _parseChineseNumber(String s) {
  const digits = {
    '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
    '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
  };
  const units = {'十': 10, '百': 100, '千': 1000, '万': 10000};
  var total = 0;
  var section = 0;
  var number = 0;
  for (final ch in s.split('')) {
    if (digits.containsKey(ch)) {
      number = digits[ch]!;
    } else if (units.containsKey(ch)) {
      final unit = units[ch]!;
      if (ch == '万') {
        section = (section + number) * unit;
        total += section;
        section = 0;
        number = 0;
      } else {
        section += (number == 0 ? 1 : number) * unit;
        number = 0;
      }
    } else {
      return -1;
    }
  }
  return total + section + number;
}

/// int → 中文数字串（1..99999999；超出范围回退阿拉伯数字）。
String _toChineseNumber(int n) {
  assert(n > 0);
  if (n >= 100000000) return n.toString();
  const d = '零一二三四五六七八九';
  const u = ['', '十', '百', '千'];
  String below10000(int g) {
    final s = g.toString();
    final buf = StringBuffer();
    var prevZero = false;
    for (var i = 0; i < s.length; i++) {
      final digit = s.codeUnitAt(i) - 0x30;
      final pos = s.length - 1 - i;
      if (digit == 0) {
        prevZero = true;
      } else {
        if (prevZero) buf.write('零');
        buf.write(d[digit]);
        buf.write(u[pos]);
        prevZero = false;
      }
    }
    var r = buf.toString();
    // 10-19 省略开头的「一」：一十 → 十。
    if (r.startsWith('一十')) r = '十${r.substring(2)}';
    return r;
  }
  final wan = n ~/ 10000;
  final ge = n % 10000;
  final buf = StringBuffer();
  if (wan > 0) buf.write('${below10000(wan)}万');
  if (ge > 0) {
    // 万级后个级不足千时补零，如 一万零五。
    if (wan > 0 && ge < 1000) buf.write('零');
    buf.write(below10000(ge));
  }
  return buf.toString();
}

class Sidebar extends StatefulWidget {
  const Sidebar({
    super.key,
    required this.library,
    required this.settings,
    this.onBack,
    this.onOpenBookSearch,
  });

  final LibraryController library;
  final SettingsController settings;

  /// 返回笔记本管理页（null = 未接线，如测试；顶栏隐藏返回键）。
  final VoidCallback? onBack;

  /// 全书搜索入口（null = 未接线，如测试；顶栏隐藏搜索按钮）。
  final VoidCallback? onOpenBookSearch;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  _EditSession? _editing;

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
    super.dispose();
  }

  /// 树数据来自 controller，任何变更都刷新自身（壳层 ListenableBuilder 之外也自洽）。
  void _onLibraryChanged() {
    if (mounted) setState(() {});
  }

  bool _isEditingDocument(String id) =>
      _editing?.target == _EditTarget.document && _editing?.id == id;

  /// 校验：空名 / 非法字符 / 同名冲突（限当前书内）。
  String? _validateName(_EditSession session, String value) {
    final name = value.trim();
    if (name.isEmpty) return '名称不能为空';
    if (name.contains('/') || name.contains('\\')) return '名称不能包含 / 或 \\';
    final library = widget.library;
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
  Future<void> _createDocumentDirect(String notebookId) async {
    final title = suggestedChapterTitle(
      widget.library.documentsOf(notebookId),
    );
    await widget.library.createDocument(notebookId, title: title);
  }

  /// 打开「针对这本书的设置」对话框。
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
            ),
            Expanded(
              child: nb == null
                  ? const SizedBox.shrink()
                  : widget.library.loading
                  ? const _LoadingSkeleton()
                  : _buildTree(nb),
            ),
          ],
        ),
      ),
    );
  }

  /// 单书章节树：分卷开启时按每卷章数插入「第 N 卷」分组标题。
  Widget _buildTree(Notebook nb) {
    final library = widget.library;
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final children = <Widget>[];
    final refs = <TreeRowRef>[];

    void add(Widget child, TreeRowRef ref) {
      children.add(child);
      refs.add(ref);
    }

    final docs = library.documentsOf(nb.id);
    final volume = widget.settings.volumeForNotebook(nb.id);

    var docIndex = 0;
    var volumeNumber = 1;
    for (final doc in docs) {
      if (volume.enabled && docIndex % volume.chapters == 0) {
        add(
          _VolumeHeader(
            key: ValueKey('vol-${nb.id}-$volumeNumber'),
            volumeNumber: volumeNumber++,
          ),
          TreeRowRef(notebookId: nb.id, isHeader: true),
        );
      }
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
      docIndex++;
    }
    if (docs.isNotEmpty) {
      add(
        _NewDocumentButton(
          key: ValueKey('new-doc-${nb.id}'),
          onPressed: () => _createDocumentDirect(nb.id),
        ),
        TreeRowRef(notebookId: nb.id),
      );
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

  /// 章节行 + 拖拽接线：桌面端仅手柄可拖（行体点击不受干扰），
  /// 触摸端整行长按拖拽（短按仍是切换文档）。
  Widget _documentRow(Notebook nb, Document doc, int index) {
    final library = widget.library;
    final tile = _DocumentTile(
      key: ValueKey('doc-${doc.id}'),
      index: index,
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
      onMoveUp: () => library.moveDocument(doc.id, up: true),
      onMoveDown: () => library.moveDocument(doc.id, up: false),
    );
    if (!isDesktopPlatform) {
      return ReorderableDelayedDragStartListener(index: index, child: tile);
    }
    return tile;
  }

  /// 拖拽落点：映射为（目标笔记本, 位置）后写库（映射逻辑见 reorderTarget）。
  ///
  /// onReorderItem 语义：newIndex 是「移除拖拽行之后」的插入位（已调整）。
  void _onReorderItem(int oldIndex, int newIndex) {
    final refs = _rowRefs;
    final target = reorderTarget(refs, oldIndex, newIndex);
    if (target == null) return;
    final docId = refs[oldIndex].docId;
    if (docId == null) return;
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

/// 单书工作区顶栏：返回 + 书名 + 全书搜索 + 本书设置。
class _BookHeader extends StatelessWidget {
  const _BookHeader({
    required this.title,
    this.onBack,
    this.onOpenBookSettings,
    this.onOpenBookSearch,
  });

  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onOpenBookSettings;
  final VoidCallback? onOpenBookSearch;

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
          if (onOpenBookSearch != null)
            ZzIconButton(
              tooltip: '全书搜索 (${isMacOS ? '⌘' : 'Ctrl'}+P)',
              icon: Icons.search,
              onPressed: onOpenBookSearch!,
            ),
          if (onOpenBookSettings != null)
            ZzIconButton(
              tooltip: '这本书的设置',
              icon: Icons.settings_outlined,
              onPressed: onOpenBookSettings!,
            ),
        ],
      ),
    );
  }
}

/// 分卷分组标题：单书工作区按每卷章数插入「第 N 卷」，非交互行。
class _VolumeHeader extends StatelessWidget {
  const _VolumeHeader({super.key, required this.volumeNumber});

  final int volumeNumber;

  @override
  Widget build(BuildContext context) {
    final appColors = appColorsOf(context);
    return Container(
      height: 28,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      child: Text(
        '第${_toChineseNumber(volumeNumber)}卷',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
          color: appColors.textTertiary,
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
            ('上移', Icons.arrow_upward, widget.onMoveUp),
            ('下移', Icons.arrow_downward, widget.onMoveDown),
            ('重命名', Icons.drive_file_rename_outline, widget.onEdit),
            ('删除', Icons.delete_outline, widget.onDelete),
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
    if (!isDesktopPlatform) return chapterIcon; // 触摸端整行长按拖拽，无需手柄
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
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onCancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: ZzTextField(
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
class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.visible, required this.items});

  final bool visible;
  final List<(String, IconData, VoidCallback)> items;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 90),
      opacity: visible ? 1 : 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: PopupMenuButton<String>(
          tooltip: '操作',
          icon: Icon(
            Icons.more_horiz,
            size: 16,
            color: colors.onSurfaceVariant,
          ),
          onSelected: (key) {
            for (final (label, _, action) in items) {
              if (label == key) action();
            }
          },
          itemBuilder: (context) => [
            for (final (label, icon, _) in items)
              PopupMenuItem<String>(
                value: label,
                height: 34,
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 15,
                      color: label == '删除'
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 9),
                    Text(
                      label,
                      style: label == '删除'
                          ? TextStyle(color: colors.error)
                          : null,
                    ),
                  ],
                ),
              ),
          ],
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

