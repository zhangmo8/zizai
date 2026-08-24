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
import '../util/platform.dart';
import 'zz.dart';

enum _EditTarget { notebook, document }

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

  /// 文档所属笔记本（仅 document 目标需要）。
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
    this.onOpenSettings,
    this.onOpenBookSearch,
  });

  final LibraryController library;
  final VoidCallback? onOpenSettings;

  /// 全书搜索入口（null = 未接线，如测试；顶栏隐藏搜索按钮）。
  final VoidCallback? onOpenBookSearch;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final Set<String> _expanded = {};
  bool _seededExpansion = false;
  _EditSession? _editing;

  /// 最近一次构建的行引用（拖拽落点时把扁平索引映射回笔记本/位置）。
  List<TreeRowRef> _rowRefs = const [];

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_onLibraryChanged);
  }

  @override
  void didUpdateWidget(covariant Sidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.removeListener(_onLibraryChanged);
      widget.library.addListener(_onLibraryChanged);
    }
  }

  @override
  void dispose() {
    widget.library.removeListener(_onLibraryChanged);
    super.dispose();
  }

  /// 树数据来自 controller，任何变更都刷新自身（壳层 ListenableBuilder 之外也自洽）。
  void _onLibraryChanged() {
    if (mounted) setState(() {});
  }

  bool get _editingNewNotebook =>
      _editing?.target == _EditTarget.notebook && _editing?.id == null;

  bool get _editingNewDocument =>
      _editing?.target == _EditTarget.document && _editing?.id == null;

  bool _isEditingNotebook(String id) =>
      _editing?.target == _EditTarget.notebook && _editing?.id == id;

  bool _isEditingDocument(String id) =>
      _editing?.target == _EditTarget.document && _editing?.id == id;

  /// 校验：空名 / 非法字符 / 同名冲突（文档仅限同笔记本内）。
  String? _validateName(_EditSession session, String value) {
    final name = value.trim();
    if (name.isEmpty) return '名称不能为空';
    if (name.contains('/') || name.contains('\\')) return '名称不能包含 / 或 \\';
    final library = widget.library;
    final dup = session.target == _EditTarget.notebook
        ? library.notebooks.any((n) => n.name == name && n.id != session.id)
        : library
              .documentsOf(session.notebookId ?? '')
              .any((d) => d.title == name && d.id != session.id);
    return dup ? '同名已存在' : null;
  }

  Future<void> _commitEdit(String rawValue) async {
    final session = _editing;
    if (session == null) return;
    if (_validateName(session, rawValue) != null) return; // 错误态由输入框持有
    final name = rawValue.trim();
    if (session.target == _EditTarget.notebook) {
      if (session.id == null) {
        final nb = await widget.library.createNotebook(name);
        // 保留编辑行直到写库完成，避免列表先塌缩再插入新行造成高度闪烁。
        if (mounted) {
          setState(() {
            _expanded.add(nb.id);
            _editing = null;
          });
        }
      } else {
        await widget.library.renameNotebook(session.id!, name);
        if (mounted) setState(() => _editing = null);
      }
    } else {
      final notebookId = session.notebookId;
      if (notebookId == null) return;
      if (session.id == null) {
        await widget.library.createDocument(notebookId, title: name);
      } else {
        await widget.library.renameDocument(session.id!, name);
      }
      if (mounted) setState(() => _editing = null);
    }
  }

  void _cancelEdit() => setState(() => _editing = null);

  void _startEdit(_EditSession session) => setState(() => _editing = session);

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    // 默认展开全部笔记本（首次加载后）。
    if (!_seededExpansion && library.notebooks.isNotEmpty) {
      _seededExpansion = true;
      _expanded.addAll(library.notebooks.map((n) => n.id));
    }
    return ColoredBox(
      color: appColorsOf(context).sidebar,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _HeaderBar(
              onOpenBookSearch: widget.onOpenBookSearch,
              onNewNotebook: () => _startEdit(
                const _EditSession(
                  target: _EditTarget.notebook,
                  initial: '新笔记本',
                ),
              ),
            ),
            Expanded(
              child: library.loading
                  ? const _LoadingSkeleton()
                  : library.notebooks.isEmpty && !_editingNewNotebook
                  ? _EmptyState(
                      onCreate: () => _startEdit(
                        const _EditSession(
                          target: _EditTarget.notebook,
                          initial: '新笔记本',
                        ),
                      ),
                    )
                  : _buildTree(),
            ),
            if (widget.onOpenSettings != null)
              _SidebarFooter(onOpenSettings: widget.onOpenSettings!),
          ],
        ),
      ),
    );
  }

  Widget _buildTree() {
    final library = widget.library;
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final children = <Widget>[];
    final refs = <TreeRowRef>[];

    void add(Widget child, TreeRowRef ref) {
      children.add(child);
      refs.add(ref);
    }

    for (final nb in library.notebooks) {
      if (_isEditingNotebook(nb.id)) {
        add(
          _editField(_editing!, nb.id, key: ValueKey('edit-nb-${nb.id}')),
          TreeRowRef(notebookId: nb.id),
        );
      } else {
        add(
          _NotebookTile(
            key: ValueKey('nb-${nb.id}'),
            notebook: nb,
            expanded: _expanded.contains(nb.id),
            onToggle: () => setState(() {
              if (!_expanded.add(nb.id)) _expanded.remove(nb.id);
            }),
            onNewDocument: () {
              // Notion 式行内 +：展开该笔记本并进入新章节命名。
              setState(() => _expanded.add(nb.id));
              _startEdit(
                _EditSession(
                  target: _EditTarget.document,
                  initial: suggestedChapterTitle(library.documentsOf(nb.id)),
                  notebookId: nb.id,
                ),
              );
            },
            onEdit: () => _startEdit(
              _EditSession(
                id: nb.id,
                target: _EditTarget.notebook,
                initial: nb.name,
              ),
            ),
            onDelete: () => library.requestDelete(
              kind: DeletionKind.notebook,
              id: nb.id,
              name: nb.name,
            ),
            onMoveUp: () => library.moveNotebook(nb.id, up: true),
            onMoveDown: () => library.moveNotebook(nb.id, up: false),
          ),
          TreeRowRef(notebookId: nb.id, isHeader: true),
        );
      }
      if (_expanded.contains(nb.id)) {
        for (final doc in library.documentsOf(nb.id)) {
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
        if (_editingNewDocument && _editing!.notebookId == nb.id) {
          add(
            _editField(
              _editing!,
              null,
              notebookId: nb.id,
              key: ValueKey('edit-doc-new-${nb.id}'),
            ),
            TreeRowRef(notebookId: nb.id),
          );
        } else {
          add(
            _NewDocumentButton(
              key: ValueKey('new-doc-${nb.id}'),
              onPressed: () => _startEdit(
                _EditSession(
                  target: _EditTarget.document,
                  initial: suggestedChapterTitle(library.documentsOf(nb.id)),
                  notebookId: nb.id,
                ),
              ),
            ),
            TreeRowRef(notebookId: nb.id),
          );
        }
      }
    }
    if (_editingNewNotebook) {
      add(
        _editField(_editing!, null, key: const ValueKey('edit-nb-new')),
        const TreeRowRef(),
      );
    }
    _rowRefs = refs;

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
      dragHandle: isDesktopPlatform
          ? ReorderableDragStartListener(
              index: index,
              child: GestureDetector(
                // 消费手柄区域的点击：pan 手势在「点击（无拖动）」时未确认会
                // 落到行体 InkWell 触发切换文档，这里用空 onTap 拦截（拖拽时
                // pan 胜出，tap 落选，不影响拖动）。
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: const _GripIcon(),
              ),
            )
          : const _GripIcon(),
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
      padding: EdgeInsets.fromLTRB(
        resolved.target == _EditTarget.notebook ? 10 : 34,
        2,
        4,
        2,
      ),
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

/// 固定在侧边栏底部的设置入口，与文档树分层。
class _SidebarFooter extends StatefulWidget {
  const _SidebarFooter({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  State<_SidebarFooter> createState() => _SidebarFooterState();
}

class _SidebarFooterState extends State<_SidebarFooter> {
  bool _hovered = false;
  bool _pressed = false;

  void _open() {
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onOpenSettings();
      });
      return;
    }
    widget.onOpenSettings();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outline)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Tooltip(
          message: '设置',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapCancel: () => setState(() => _pressed = false),
              onTapUp: (_) => setState(() => _pressed = false),
              onTap: _open,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                curve: Curves.easeOut,
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: _pressed
                      ? appColors.rowSelected
                      : _hovered
                      ? appColors.surfaceHover
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.settings_outlined,
                      size: 17,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        '设置',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: appColors.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶栏：品牌 Logo + 全书搜索 + 新建笔记本按钮。
class _HeaderBar extends StatelessWidget {
  const _HeaderBar({required this.onNewNotebook, this.onOpenBookSearch});

  final VoidCallback onNewNotebook;
  final VoidCallback? onOpenBookSearch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.asset(
              'assets/logo.png',
              width: 32,
              height: 32,
              fit: BoxFit.cover,
              semanticLabel: '字在',
            ),
          ),
          const Spacer(),
          if (onOpenBookSearch != null)
            _TinyIconButton(
              tooltip: '全书搜索 (${isMacOS ? '⌘' : 'Ctrl'}+P)',
              icon: Icons.search,
              onPressed: onOpenBookSearch!,
            ),
          _TinyIconButton(
            tooltip: '新建笔记本',
            icon: Icons.add,
            onPressed: onNewNotebook,
          ),
        ],
      ),
    );
  }
}

/// 笔记本行：展开/折叠 + hover 浮现「+ 新建章节」与 ⋯ 操作菜单。
class _NotebookTile extends StatefulWidget {
  const _NotebookTile({
    super.key,
    required this.notebook,
    required this.expanded,
    required this.onToggle,
    required this.onNewDocument,
    required this.onEdit,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final Notebook notebook;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onNewDocument;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  @override
  State<_NotebookTile> createState() => _NotebookTileState();
}

class _NotebookTileState extends State<_NotebookTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: _SidebarRow(
        depth: 0,
        hover: _hover,
        selected: false,
        onTap: widget.onToggle,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedRotation(
              duration: const Duration(milliseconds: 120),
              turns: widget.expanded ? 0.25 : 0,
              child: Icon(
                Icons.chevron_right,
                size: 16,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 5),
            Icon(
              Icons.folder_outlined,
              size: 16,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
        title: widget.notebook.name,
        titleStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HoverReveal(
              visible: _hover || !isDesktopPlatform,
              child: _QuickAddButton(onPressed: widget.onNewDocument),
            ),
            _RowMenu(
              visible: _hover || !isDesktopPlatform,
              items: [
                ('上移', Icons.arrow_upward, widget.onMoveUp),
                ('下移', Icons.arrow_downward, widget.onMoveDown),
                ('重命名', Icons.drive_file_rename_outline, widget.onEdit),
                ('删除', Icons.delete_outline, widget.onDelete),
              ],
            ),
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
    required this.document,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
    this.dragHandle,
  });

  final Document document;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;

  /// 拖拽手柄（桌面端由 ReorderableDragStartListener 包裹；触摸端为纯提示图标）。
  final Widget? dragHandle;

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
        leading: Icon(
          Icons.description_outlined,
          size: 15,
          color: widget.selected ? colors.onSurface : colors.onSurfaceVariant,
        ),
        title: widget.document.title,
        titleStyle: TextStyle(
          fontSize: 13,
          fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
          color: widget.selected ? colors.onSurface : colors.onSurfaceVariant,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.dragHandle != null)
              _HoverReveal(
                visible: _hover || !isDesktopPlatform,
                child: widget.dragHandle!,
              ),
            _RowMenu(
              visible: _hover || !isDesktopPlatform,
              items: [
                ('上移', Icons.arrow_upward, widget.onMoveUp),
                ('下移', Icons.arrow_downward, widget.onMoveDown),
                ('重命名', Icons.drive_file_rename_outline, widget.onEdit),
                ('删除', Icons.delete_outline, widget.onDelete),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 拖拽排序手柄：桌面端 hover 浮现（ReorderableDragStartListener 包裹，
/// 仅手柄可拖，行体点击不受影响）；触摸端常显，仅作长按拖拽的提示。
class _GripIcon extends StatelessWidget {
  const _GripIcon();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Icon(
        Icons.drag_indicator,
        size: 15,
        color: colors.onSurfaceVariant,
      ),
    );
  }
}

/// hover 才浮现的轻量容器（桌面端低打扰 chrome）。
class _HoverReveal extends StatelessWidget {
  const _HoverReveal({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 90),
      opacity: visible ? 1 : 0,
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }
}

/// 笔记本行的快捷「+」：新建章节。
class _QuickAddButton extends StatelessWidget {
  const _QuickAddButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: '新建章节',
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
      icon: Icon(Icons.add, size: 16, color: colors.onSurfaceVariant),
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
              const SizedBox(width: 6),
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

/// 空库引导。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: appColors.rowSelected,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.outline),
              ),
              child: Icon(
                Icons.menu_book_outlined,
                size: 22,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '新建一本笔记本，开始写',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            _NotionButton(onPressed: onCreate, child: const Text('新建笔记本')),
          ],
        ),
      ),
    );
  }
}

class _TinyIconButton extends StatelessWidget {
  const _TinyIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      icon: Icon(icon, size: 18, color: colors.onSurfaceVariant),
    );
  }
}

class _NotionButton extends StatelessWidget {
  const _NotionButton({required this.onPressed, required this.child});

  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: colors.onSurface,
        backgroundColor: appColors.surfaceRaised,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: colors.outline),
        ),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        child: child,
      ),
    );
  }
}
