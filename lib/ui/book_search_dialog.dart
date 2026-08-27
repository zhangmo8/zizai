/// 全书搜索对话框：按章节分组的跨文档搜索，点击命中跳转，
/// 支持全书替换（替换前预览 → 确认 → 执行）。
///
/// 设计依据：docs/app/ui-sidebar.md §全书搜索、design.md（6px 浮层、
/// 4px 条目、hover 反馈、accent 高亮命中词）。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;
import '../core/book_search.dart';
import '../core/models.dart' show Notebook;
import '../state/library_controller.dart';
import '../util/debounce.dart';
import 'zz.dart';

/// 打开全书搜索。[onOpen] 收到被点中的命中（对话框已关闭后调用）。
Future<void> showBookSearchDialog(
  BuildContext context, {
  required LibraryController library,
  required void Function(BookSearchHit hit) onOpen,
  String? scopeNotebookId,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      alignment: const Alignment(0, -0.4),
      child: _BookSearchPanel(
        library: library,
        onOpen: onOpen,
        scopeNotebookId: scopeNotebookId,
      ),
    ),
  );
}

class _BookSearchPanel extends StatefulWidget {
  const _BookSearchPanel({
    required this.library,
    required this.onOpen,
    this.scopeNotebookId,
  });

  final LibraryController library;
  final void Function(BookSearchHit hit) onOpen;

  /// 非 null 时只搜索该书（单书工作区）；null = 全书搜索。
  final String? scopeNotebookId;

  @override
  State<_BookSearchPanel> createState() => _BookSearchPanelState();
}

class _BookSearchPanelState extends State<_BookSearchPanel> {
  final TextEditingController _query = TextEditingController();
  final TextEditingController _replacement = TextEditingController();
  final Debouncer _debounce = Debouncer(const Duration(milliseconds: 250));

  List<BookSearchGroup> _groups = const [];
  bool _searching = false;

  /// 替换预览面板是否展开。
  bool _showReplace = false;

  /// 替换预览结果。
  List<ReplacePreview> _previews = const [];
  bool _previewing = false;
  bool _replacing = false;

  /// 已出结果的查询（区分「未搜索」与「无结果」）；乱序结果用它丢弃。
  String _searchedQuery = '';
  int _searchSeq = 0;

  @override
  void dispose() {
    _query.dispose();
    _replacement.dispose();
    _debounce.cancel();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _debounce.schedule(_runSearch);
    setState(() {}); // 计数区即时清空观感
  }

  Future<void> _runSearch() async {
    final query = _query.text.trim();
    final seq = ++_searchSeq;
    if (query.isEmpty) {
      setState(() {
        _groups = const [];
        _searchedQuery = '';
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final scope = widget.scopeNotebookId;
    final groups = await searchBook(
      notebooks: _scopeNotebooks(),
      documentsOf: (id) =>
          scope != null && id != scope ? const [] : widget.library.documentsOf(id),
      query: query,
    );
    if (!mounted || seq != _searchSeq) return; // 已有更新的查询在跑
    setState(() {
      _groups = groups;
      _searchedQuery = query;
      _searching = false;
    });
  }

  /// 限定在单书工作区时只搜索当前书。
  List<Notebook> _scopeNotebooks() {
    final scope = widget.scopeNotebookId;
    if (scope == null) return widget.library.notebooks;
    return [
      for (final nb in widget.library.notebooks)
        if (nb.id == scope) nb,
    ];
  }

  void _open(BookSearchHit hit) {
    Navigator.of(context).pop();
    widget.onOpen(hit);
  }

  /// 生成替换预览。
  Future<void> _runPreview() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() => _previewing = true);
    final scope = widget.scopeNotebookId;
    final previews = await previewReplaceInBook(
      notebooks: _scopeNotebooks(),
      documentsOf: (id) =>
          scope != null && id != scope ? const [] : widget.library.documentsOf(id),
      query: query,
      replacement: _replacement.text,
    );
    if (!mounted) return;
    setState(() {
      _previews = previews;
      _previewing = false;
    });
  }

  /// 执行全书替换。
  Future<void> _executeReplace() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() => _replacing = true);
    final scope = widget.scopeNotebookId;
    try {
      final total = await replaceAllInBook(
        notebooks: _scopeNotebooks(),
        documentsOf: (id) =>
            scope != null && id != scope ? const [] : widget.library.documentsOf(id),
        query: query,
        replacement: _replacement.text,
        saveDocument: ({
          required documentId,
          required title,
          required content,
        }) async {
          await widget.library.saveDocument(
            documentId: documentId,
            title: title,
            content: content,
            writtenWords: 0,
          );
        },
      );
      if (!mounted) return;
      showZzToast(
        context,
        total > 0 ? '已替换 $total 处' : '没有找到匹配项',
        error: total == 0,
      );
      Navigator.of(context).pop();
    } catch (e, stackTrace) {
      await widget.library.logger?.error(
        'book.replace.failed',
        e,
        stackTrace,
        data: {'query': _replacement.text},
      );
      if (!mounted) return;
      showZzToast(context, '替换失败，请重试', error: true);
    } finally {
      if (mounted) setState(() => _replacing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    return SizedBox(
      width: (size.width - 48).clamp(320.0, 640.0),
      height: (size.height - 96).clamp(280.0, 520.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Column(
              children: [
                Row(
                  children: [
                    _iconBtn(
                      icon: _showReplace
                          ? Icons.expand_less
                          : Icons.expand_more,
                      tooltip: _showReplace ? '收起替换' : '展开替换',
                      onTap: () => setState(() => _showReplace = !_showReplace),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: ZzTextField(
                        controller: _query,
                        hint: '全书搜索：人名、地名、称呼、设定…',
                        autofocus: true,
                        compact: true,
                        onChanged: _onQueryChanged,
                        onSubmitted: (_) => _runPreview(),
                      ),
                    ),
                  ],
                ),
                if (_showReplace) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const SizedBox(width: 30),
                      Expanded(
                        child: ZzTextField(
                          controller: _replacement,
                          hint: '替换为',
                          compact: true,
                          onSubmitted: (_) => _runPreview(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      TextButton(
                        onPressed: _query.text.trim().isEmpty || _previewing
                            ? null
                            : _runPreview,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        child: Text(
                          _previewing ? '预览中…' : '预览',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: colors.outline),
          // 替换预览面板优先显示
          Expanded(
            child: _previews.isNotEmpty
                ? _replacePreviewList(context)
                : _results(context),
          ),
          if (_previews.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.outline)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '将替换 ${_previews.fold<int>(0, (s, p) => s + p.matchCount)} 处',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _previews = const []),
                    child: const Text('取消', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _replacing ? null : _executeReplace,
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: colors.onPrimary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child: Text(
                      _replacing ? '替换中…' : '全部替换',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _iconBtn({
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
  }) {
    final appColors = appColorsOf(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            size: 15,
            color: onTap == null
                ? appColors.textTertiary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _replacePreviewList(BuildContext context) {
    final appColors = appColorsOf(context);
    final total = _previews.fold<int>(0, (s, p) => s + p.matchCount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
          child: Text(
            '替换预览 · $total 处 · ${_previews.length} 章',
            style: TextStyle(fontSize: 11.5, color: appColors.textTertiary),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            itemCount: _previews.length,
            itemBuilder: (context, index) =>
                _previewGroup(context, _previews[index]),
          ),
        ),
      ],
    );
  }

  Widget _previewGroup(BuildContext context, ReplacePreview preview) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
          child: Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 13,
                color: appColors.textTertiary,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  preview.documentTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${preview.matchCount}',
                style: TextStyle(fontSize: 11, color: appColors.textTertiary),
              ),
            ],
          ),
        ),
        for (final r in preview.replacements)
          _ReplaceTile(before: r.before, after: r.after),
      ],
    );
  }

  Widget _results(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    if (_query.text.trim().isEmpty) {
      return Center(
        child: Text(
          '输入关键词，跨全部章节查找',
          style: TextStyle(fontSize: 12.5, color: appColors.textTertiary),
        ),
      );
    }
    if (_searching && _searchedQuery != _query.text.trim()) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_groups.isEmpty) {
      return Center(
        child: Text(
          '全书没有找到「${_searchedQuery.length > 20 ? '${_searchedQuery.substring(0, 20)}…' : _searchedQuery}」',
          style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
        ),
      );
    }
    final shown = _groups.fold<int>(0, (sum, g) => sum + g.hits.length);
    final total = _groups.fold<int>(0, (sum, g) => sum + g.totalMatches);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
          child: Text(
            total > shown
                ? '$total 处匹配 · ${_groups.length} 章（仅显示前 $shown 处）'
                : '$total 处匹配 · ${_groups.length} 章',
            style: TextStyle(fontSize: 11.5, color: appColors.textTertiary),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            itemCount: _groups.length,
            itemBuilder: (context, index) =>
                _group(context, _groups[index]),
          ),
        ),
      ],
    );
  }

  Widget _group(BuildContext context, BookSearchGroup group) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
          child: Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 13,
                color: appColors.textTertiary,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  '${group.notebookName} / ${group.documentTitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${group.totalMatches}',
                style: TextStyle(fontSize: 11, color: appColors.textTertiary),
              ),
            ],
          ),
        ),
        for (final hit in group.hits) _HitTile(hit: hit, onTap: () => _open(hit)),
      ],
    );
  }
}

/// 替换预览行：删除线原文本 → 替换后文本。
class _ReplaceTile extends StatelessWidget {
  const _ReplaceTile({required this.before, required this.after});

  final String before;
  final String after;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            before,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: colors.onSurfaceVariant,
              decoration: TextDecoration.lineThrough,
              decorationColor: colors.error,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            after,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: colors.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _HitTile extends StatefulWidget {
  const _HitTile({required this.hit, required this.onTap});

  final BookSearchHit hit;
  final VoidCallback onTap;

  @override
  State<_HitTile> createState() => _HitTileState();
}

class _HitTileState extends State<_HitTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    final hit = widget.hit;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: _hover ? appColors.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: hit.preview.substring(0, hit.previewMatchStart)),
                TextSpan(
                  text: hit.preview.substring(
                    hit.previewMatchStart,
                    hit.previewMatchEnd,
                  ),
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(text: hit.preview.substring(hit.previewMatchEnd)),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
