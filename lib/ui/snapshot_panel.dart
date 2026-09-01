/// 版本历史面板：快照列表 + 预览 + 手动留存 + 回滚。
///
/// 设计依据：docs/app/ui-editor.md §版本历史、design.md（6px 卡片、
/// 4px 条目圆角、hover/selected 反馈、右下角文字按钮、危险操作确认）。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;
import '../core/export.dart' show deltaToPlainText;
import '../core/models.dart' as m;
import '../core/snapshot_history.dart';
import '../util/date_format.dart' show formatSnapshotTime;
import 'zz.dart';

/// 打开版本历史对话框。[document] 应为已 flush 保存的当前文档；
/// [onRestore] 负责留底 + 写库 + 编辑器重载，成功后对话框自行关闭。
Future<void> showSnapshotHistory(
  BuildContext context, {
  required SnapshotHistory history,
  required m.Document document,
  required Future<bool> Function(DocumentSnapshot snapshot) onRestore,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: _SnapshotPanel(
        history: history,
        document: document,
        onRestore: onRestore,
      ),
    ),
  );
}

class _SnapshotPanel extends StatefulWidget {
  const _SnapshotPanel({
    required this.history,
    required this.document,
    required this.onRestore,
  });

  final SnapshotHistory history;
  final m.Document document;
  final Future<bool> Function(DocumentSnapshot snapshot) onRestore;

  @override
  State<_SnapshotPanel> createState() => _SnapshotPanelState();
}

class _SnapshotPanelState extends State<_SnapshotPanel> {
  List<DocumentSnapshot>? _snapshots;
  int _selected = 0;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({int select = 0}) async {
    final snapshots = await widget.history.list(widget.document.id);
    if (!mounted) return;
    setState(() {
      _snapshots = snapshots;
      _selected = snapshots.isEmpty
          ? 0
          : select.clamp(0, snapshots.length - 1);
    });
  }

  Future<void> _snapshotNow() async {
    await widget.history.create(widget.document);
    if (!mounted) return;
    showZzToast(context, '已留存当前版本');
    await _load();
  }

  Future<void> _deleteSelected(DocumentSnapshot snapshot) async {
    final ok = await zzConfirm(
      context,
      title: '删除此版本？',
      message: '仅删除 ${formatSnapshotTime(snapshot.createdAt)} 的历史留底，不影响正文。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok || !mounted) return;
    await widget.history.delete(snapshot);
    if (mounted) await _load(select: _selected);
  }

  Future<void> _restore(DocumentSnapshot snapshot) async {
    final ok = await zzConfirm(
      context,
      title: '回滚到此版本？',
      message:
          '正文将回到 ${formatSnapshotTime(snapshot.createdAt)}（${snapshot.words} 字）。'
          '当前内容会先自动留底，可随时再回来。',
      confirmLabel: '回滚',
    );
    if (!ok || !mounted) return;
    setState(() => _restoring = true);
    final done = await widget.onRestore(snapshot);
    if (!mounted) return;
    setState(() => _restoring = false);
    if (done) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final snapshots = _snapshots;
    return SizedBox(
      width: (size.width - 48).clamp(320.0, 680.0),
      height: (size.height - 96).clamp(280.0, 480.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${widget.document.title} · 版本历史',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ZzButton.secondary(label: '留存当前版本', onPressed: _snapshotNow),
                const SizedBox(width: 8),
              ],
            ),
          ),
          Divider(height: 1, color: colors.outline),
          Expanded(
            child: snapshots == null
                ? const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : snapshots.isEmpty
                ? _empty(context)
                : _body(context, snapshots),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 28, color: appColors.textTertiary),
          const SizedBox(height: 10),
          Text(
            '还没有历史版本',
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            '写作过程中会自动留底；也可以手动「留存当前版本」',
            style: TextStyle(fontSize: 12, color: appColors.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, List<DocumentSnapshot> snapshots) {
    final colors = Theme.of(context).colorScheme;
    final selected = snapshots[_selected.clamp(0, snapshots.length - 1)];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 200,
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: snapshots.length,
            itemBuilder: (context, index) => _SnapshotTile(
              snapshot: snapshots[index],
              time: formatSnapshotTime(snapshots[index].createdAt),
              selected: index == _selected,
              onTap: () => setState(() => _selected = index),
            ),
          ),
        ),
        VerticalDivider(width: 1, color: colors.outline),
        Expanded(child: _previewPane(context, selected)),
      ],
    );
  }

  Widget _previewPane(BuildContext context, DocumentSnapshot snapshot) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    String preview;
    try {
      preview = deltaToPlainText(snapshot.content);
    } on FormatException {
      preview = '';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: preview.isEmpty
              ? Center(
                  child: Text(
                    '（此版本没有正文）',
                    style: TextStyle(
                      fontSize: 12,
                      color: appColors.textTertiary,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Text(
                    preview,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.8,
                      color: colors.onSurface,
                    ),
                  ),
                ),
        ),
        Divider(height: 1, color: colors.outline),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Text(
                '${formatSnapshotTime(snapshot.createdAt)} · ${snapshot.words} 字',
                style: TextStyle(fontSize: 12, color: appColors.textTertiary),
              ),
              const Spacer(),
              ZzButton.link(
                label: '删除',
                color: colors.error,
                onPressed: _restoring ? null : () => _deleteSelected(snapshot),
              ),
              const SizedBox(width: 4),
              ZzButton.primary(
                label: '回滚到此版本',
                busy: _restoring,
                onPressed: _restoring ? null : () => _restore(snapshot),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SnapshotTile extends StatefulWidget {
  const _SnapshotTile({
    required this.snapshot,
    required this.time,
    required this.selected,
    required this.onTap,
  });

  final DocumentSnapshot snapshot;
  final String time;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SnapshotTile> createState() => _SnapshotTileState();
}

class _SnapshotTileState extends State<_SnapshotTile> {
  bool _hover = false;

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
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: widget.selected
                ? appColors.rowSelected
                : _hover
                ? appColors.surfaceHover
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.time,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: colors.onSurface),
              ),
              const SizedBox(height: 2),
              Text(
                '${widget.snapshot.words} 字',
                style: TextStyle(fontSize: 12, color: appColors.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
