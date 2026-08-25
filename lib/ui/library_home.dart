/// 笔记本管理层（应用入口）：网格/列表展示全部笔记本，点书进入单书工作区。
///
/// 设计依据：需求「笔记本管理单独提出来作为一个层面」——卡片不显示封面，
/// 显示书名 + 章节数 + 总字数；右上角 grid/list 视图切换；全局设置入口在此。
/// 进入工作区由 app 层门控驱动（currentNotebook != null → Shell），本页点书
/// 只调 [LibraryController.openNotebook]，不直接导航。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;
import '../core/app_logger.dart';
import '../core/backup/backup.dart';
import '../core/crash_journal.dart';
import '../core/models.dart';
import '../core/update.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import 'settings_view.dart';
import 'zz.dart';

/// 笔记本管理页。
class LibraryHome extends StatelessWidget {
  const LibraryHome({
    super.key,
    required this.library,
    required this.settings,
    this.journal,
    this.logger,
    this.backup,
    this.updateChecker,
  });

  final LibraryController library;
  final SettingsController settings;

  /// 全局设置（SettingsView）所需依赖。
  final CrashJournal? journal;
  final AppLogger? logger;
  final BackupManager? backup;
  final UpdateChecker? updateChecker;

  void _openNotebook(String notebookId) {
    library.openNotebook(notebookId);
  }

  void _openSettings(BuildContext context) {
    final view = SettingsView(
      settings: settings,
      library: library,
      backup: backup,
      logger: logger,
      updateChecker: updateChecker,
      dbSchemaVersion: updateChecker?.dbSchemaVersion,
    );
    showDialog<void>(
      context: context,
      builder: (_) =>
          Dialog(child: SizedBox(width: 840, height: 620, child: view)),
    );
  }

  Future<void> _createNotebook(BuildContext context) async {
    final name = await _promptName(context, '新建笔记本', '新笔记本');
    if (name == null || name.trim().isEmpty) return;
    await library.createNotebook(name.trim());
  }

  Future<void> _renameNotebook(BuildContext context, Notebook nb) async {
    final name = await _promptName(context, '重命名笔记本', nb.name);
    if (name == null || name.trim().isEmpty) return;
    await library.renameNotebook(nb.id, name.trim());
  }

  Future<String?> _promptName(
    BuildContext context,
    String title,
    String initial,
  ) async {
    final ok = await showDialog<String>(
      context: context,
      builder: (ctx) => _NameDialog(title: title, initial: initial),
    );
    return ok;
  }

  Future<void> _deleteNotebook(BuildContext context, Notebook nb) async {
    final confirmed = await zzConfirm(
      context,
      title: '删除笔记本「${nb.name}」？',
      message: '将删除该笔记本及其全部章节，此操作不可恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (confirmed) await library.deleteNotebook(nb.id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => _Home(
        library: library,
        onOpenNotebook: _openNotebook,
        onNewNotebook: () => _createNotebook(context),
        onRename: (nb) => _renameNotebook(context, nb),
        onDelete: (nb) => _deleteNotebook(context, nb),
        onOpenSettings: () => _openSettings(context),
      ),
    );
  }
}

enum _HomeView { grid, list }

class _Home extends StatefulWidget {
  const _Home({
    required this.library,
    required this.onOpenNotebook,
    required this.onNewNotebook,
    required this.onRename,
    required this.onDelete,
    required this.onOpenSettings,
  });

  final LibraryController library;
  final ValueChanged<String> onOpenNotebook;
  final VoidCallback onNewNotebook;
  final ValueChanged<Notebook> onRename;
  final ValueChanged<Notebook> onDelete;
  final VoidCallback onOpenSettings;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  _HomeView _view = _HomeView.grid;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final notebooks = widget.library.notebooks;
    final loading = widget.library.loading;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶栏：标题 + 视图切换 + 新建 + 全局设置
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 14, 10),
              child: Row(
                children: [
                  Text(
                    '笔记本',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                  const Spacer(),
                  _ViewToggle(
                    view: _view,
                    onChanged: (v) => setState(() => _view = v),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '新建笔记本',
                    icon: const Icon(Icons.add),
                    onPressed: widget.onNewNotebook,
                  ),
                  IconButton(
                    tooltip: '设置',
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: widget.onOpenSettings,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : notebooks.isEmpty
                  ? _EmptyHome(
                      onCreate: widget.onNewNotebook,
                    )
                  : _view == _HomeView.grid
                  ? _GridHome(
                      notebooks: notebooks,
                      library: widget.library,
                      onOpen: widget.onOpenNotebook,
                      onRename: widget.onRename,
                      onDelete: widget.onDelete,
                    )
                  : _ListHome(
                      notebooks: notebooks,
                      library: widget.library,
                      onOpen: widget.onOpenNotebook,
                      onRename: widget.onRename,
                      onDelete: widget.onDelete,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 右上角视图切换（grid / list，锚定下拉菜单）。
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.view, required this.onChanged});

  final _HomeView view;
  final ValueChanged<_HomeView> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final gridActive = view == _HomeView.grid;
    final listActive = view == _HomeView.list;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToggleIcon(
            icon: Icons.grid_view,
            tooltip: '网格视图',
            active: gridActive,
            onTap: () => onChanged(_HomeView.grid),
          ),
          _ToggleIcon(
            icon: Icons.view_list,
            tooltip: '列表视图',
            active: listActive,
            onTap: () => onChanged(_HomeView.list),
          ),
        ],
      ),
    );
  }
}

class _ToggleIcon extends StatelessWidget {
  const _ToggleIcon({
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 32,
          height: 26,
          decoration: BoxDecoration(
            color: active ? appColors.rowSelected : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            size: 16,
            color: active ? colors.primary : appColors.textTertiary,
          ),
        ),
      ),
    );
  }
}

/// 卡片网格：书名 + 章节数/总字数，无封面。
class _GridHome extends StatelessWidget {
  const _GridHome({
    required this.notebooks,
    required this.library,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  final List<Notebook> notebooks;
  final LibraryController library;
  final ValueChanged<String> onOpen;
  final ValueChanged<Notebook> onRename;
  final ValueChanged<Notebook> onDelete;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 240).floor().clamp(2, 6);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 1.5,
          ),
          itemCount: notebooks.length,
          itemBuilder: (context, index) {
            final nb = notebooks[index];
            return _NotebookCard(
              notebook: nb,
              documentCount: library.documentsOf(nb.id).length,
              words: library.wordsOf(nb.id),
              onTap: () => onOpen(nb.id),
              onRename: () => onRename(nb),
              onDelete: () => onDelete(nb),
            );
          },
        );
      },
    );
  }
}

/// 列表行：书名 + 章节数/总字数。
class _ListHome extends StatelessWidget {
  const _ListHome({
    required this.notebooks,
    required this.library,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  final List<Notebook> notebooks;
  final LibraryController library;
  final ValueChanged<String> onOpen;
  final ValueChanged<Notebook> onRename;
  final ValueChanged<Notebook> onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
      itemCount: notebooks.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final nb = notebooks[index];
        return _NotebookRow(
          notebook: nb,
          documentCount: library.documentsOf(nb.id).length,
          words: library.wordsOf(nb.id),
          onTap: () => onOpen(nb.id),
          onRename: () => onRename(nb),
          onDelete: () => onDelete(nb),
        );
      },
    );
  }
}

/// 新建/重命名笔记本的命名对话框（自身持有 controller，随退场动画安全销毁）。
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _controller,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: const InputDecoration(isDense: true),
          onSubmitted: (_) => Navigator.of(context).pop(_controller.text),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ZzButton.primary(
          label: '确定',
          onPressed: () => Navigator.of(context).pop(_controller.text),
        ),
      ],
    );
  }
}

/// 网格卡片（无封面）。
class _NotebookCard extends StatelessWidget {
  const _NotebookCard({
    required this.notebook,
    required this.documentCount,
    required this.words,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Notebook notebook;
  final int documentCount;
  final int words;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return _HoverCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  notebook.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ),
              _CardMenu(
                onRename: onRename,
                onDelete: onDelete,
              ),
            ],
          ),
          const Spacer(),
          Text(
            '$documentCount 章 · ${_fmtWords(words)} 字',
            style: TextStyle(fontSize: 12, color: appColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// 列表行。
class _NotebookRow extends StatelessWidget {
  const _NotebookRow({
    required this.notebook,
    required this.documentCount,
    required this.words,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Notebook notebook;
  final int documentCount;
  final int words;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return _HoverRow(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              notebook.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: colors.onSurface,
              ),
            ),
          ),
          Text(
            '$documentCount 章 · ${_fmtWords(words)} 字',
            style: TextStyle(fontSize: 12, color: appColors.textTertiary),
          ),
          const SizedBox(width: 4),
          _CardMenu(
            onRename: onRename,
            onDelete: onDelete,
          ),
        ],
      ),
    );
  }
}

class _CardMenu extends StatelessWidget {
  const _CardMenu({required this.onRename, required this.onDelete});

  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: Icon(Icons.more_horiz, size: 18, color: colors.onSurfaceVariant),
      padding: EdgeInsets.zero,
      splashRadius: 14,
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'rename', child: Text('重命名')),
        const PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
      onSelected: (v) => v == 'rename' ? onRename() : onDelete(),
    );
  }
}

/// 卡片容器：hover 阴影 + 边框，点击反馈。
class _HoverCard extends StatefulWidget {
  const _HoverCard({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<_HoverCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _pressed
                ? appColors.rowSelected
                : appColors.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hover ? colors.primary : colors.outline,
            ),
            boxShadow: _hover
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 列表行容器。
class _HoverRow extends StatefulWidget {
  const _HoverRow({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            color: _pressed ? appColors.rowSelected : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border(
              left: BorderSide(
                color: _hover ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined,
              size: 40, color: appColors.textTertiary),
          const SizedBox(height: 10),
          Text(
            '还没有笔记本',
            style: TextStyle(fontSize: 15, color: colors.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            '新建一本开始写作',
            style: TextStyle(fontSize: 13, color: appColors.textTertiary),
          ),
          const SizedBox(height: 16),
          ZzButton.primary(label: '新建笔记本', onPressed: onCreate),
        ],
      ),
    );
  }
}

/// 字数格式化：≥10000 → 1.2万。
String _fmtWords(int words) {
  if (words >= 10000) {
    final w = words / 10000;
    return '${w.toStringAsFixed(w >= 100 ? 0 : 1)}万';
  }
  return '$words';
}
