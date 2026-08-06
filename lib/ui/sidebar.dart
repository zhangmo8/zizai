/// 侧边栏：文档树（笔记本 ▸ 章节），CRUD 与排序交互。
///
/// 设计依据：docs/app/ui-sidebar.md（Overall Structure / Interactions /
/// State Variants / Component Tree）、docs/app/style.md（§9 侧边栏选中项、
/// 行操作 hover 浮现、空态引导）、docs/plan/analysis/modules.md（side-002 出口：
/// CRUD 与上移/下移）。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart' show appColorsOf;
import '../core/models.dart';
import '../state/library_controller.dart';
import '../util/platform.dart';

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

class Sidebar extends StatefulWidget {
  const Sidebar({super.key, required this.library});

  final LibraryController library;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final Set<String> _expanded = {};
  bool _seededExpansion = false;
  _EditSession? _editing;

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
    setState(() => _editing = null);
    if (session.target == _EditTarget.notebook) {
      if (session.id == null) {
        final nb = await widget.library.createNotebook(name);
        // 写库为真实异步：期间用户可能已关窗/切页（mounted 守卫）。
        if (mounted) setState(() => _expanded.add(nb.id));
      } else {
        await widget.library.renameNotebook(session.id!, name);
      }
    } else {
      final notebookId = session.notebookId;
      if (notebookId == null) return;
      if (session.id == null) {
        await widget.library.createDocument(notebookId, title: name);
      } else {
        await widget.library.renameDocument(session.id!, name);
      }
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
          ],
        ),
      ),
    );
  }

  Widget _buildTree() {
    final library = widget.library;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 18),
      children: [
        if (_editingNewNotebook)
          _editField(_editing!, null)
        else
          for (final nb in library.notebooks) ...[
            if (_isEditingNotebook(nb.id))
              _editField(_editing!, nb.id)
            else
              _NotebookTile(
                notebook: nb,
                expanded: _expanded.contains(nb.id),
                onToggle: () => setState(() {
                  if (!_expanded.add(nb.id)) _expanded.remove(nb.id);
                }),
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
            if (_expanded.contains(nb.id)) ...[
              for (final doc in library.documentsOf(nb.id)) ...[
                if (_isEditingDocument(doc.id))
                  _editField(_editing!, doc.id, notebookId: nb.id)
                else
                  _DocumentTile(
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
                  ),
              ],
              if (_editingNewDocument && _editing!.notebookId == nb.id)
                _editField(_editing!, null, notebookId: nb.id)
              else
                _NewDocumentButton(
                  onPressed: () => _startEdit(
                    _EditSession(
                      target: _EditTarget.document,
                      initial: '新章节.md',
                      notebookId: nb.id,
                    ),
                  ),
                ),
            ],
          ],
      ],
    );
  }

  Widget _editField(_EditSession session, String? id, {String? notebookId}) {
    final resolved = _EditSession(
      id: id,
      target: session.target,
      initial: session.initial,
      notebookId: notebookId ?? session.notebookId,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        resolved.target == _EditTarget.notebook ? 10 : 34,
        3,
        4,
        3,
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

/// 顶栏：workspace 入口 + 新建笔记本按钮。
class _HeaderBar extends StatelessWidget {
  const _HeaderBar({required this.onNewNotebook});

  final VoidCallback onNewNotebook;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 10),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: appColors.rowSelected,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: colors.outline),
            ),
            child: Text(
              '字',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '字在',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                    letterSpacing: -0.1,
                  ),
                ),
                Text(
                  '写作空间',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: appColors.textTertiary),
                ),
              ],
            ),
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

/// 笔记本行：展开/折叠 + ⋮ 操作菜单（桌面端 hover 行才浮现）。
class _NotebookTile extends StatefulWidget {
  const _NotebookTile({
    required this.notebook,
    required this.expanded,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  final Notebook notebook;
  final bool expanded;
  final VoidCallback onToggle;
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
        trailing: _RowMenu(
          visible: _hover || !isDesktopPlatform,
          items: [
            ('上移', widget.onMoveUp),
            ('下移', widget.onMoveDown),
            ('重命名', widget.onEdit),
            ('删除', widget.onDelete),
          ],
        ),
      ),
    );
  }
}

/// 文档行：选中高亮 + ⋮ 操作菜单（桌面端 hover 行才浮现）。
class _DocumentTile extends StatefulWidget {
  const _DocumentTile({
    required this.document,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onMoveUp,
    required this.onMoveDown,
  });

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
        trailing: _RowMenu(
          visible: _hover || !isDesktopPlatform,
          items: [
            ('上移', widget.onMoveUp),
            ('下移', widget.onMoveDown),
            ('重命名', widget.onEdit),
            ('删除', widget.onDelete),
          ],
        ),
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
        borderRadius: BorderRadius.circular(5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
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

  void _submit() {
    final error = widget.validate(_controller.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    widget.onSubmit(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
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
          CupertinoTextField(
            controller: _controller,
            autofocus: true,
            style: TextStyle(fontSize: 13, color: colors.onSurface),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(
                color: _error == null
                    ? colors.primary.withValues(alpha: 0.55)
                    : colors.error,
              ),
              borderRadius: BorderRadius.circular(5),
              color: appColors.surfaceRaised,
            ),
            cursorColor: colors.primary,
            onSubmitted: (_) => _submit(),
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

/// 行操作 ⋮ 菜单：桌面端由行 hover 控制显隐（低打扰 chrome），触摸端常显。
class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.visible, required this.items});

  final bool visible;
  final List<(String, VoidCallback)> items;

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
            for (final (label, action) in items) {
              if (label == key) action();
            }
          },
          itemBuilder: (context) => [
            for (final (label, _) in items)
              PopupMenuItem<String>(value: label, child: Text(label)),
          ],
        ),
      ),
    );
  }
}

/// 展开笔记本底部的「+ 新建章节」。
class _NewDocumentButton extends StatefulWidget {
  const _NewDocumentButton({required this.onPressed});

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
          borderRadius: BorderRadius.circular(5),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
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
                  borderRadius: BorderRadius.circular(99),
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
          borderRadius: BorderRadius.circular(5),
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
