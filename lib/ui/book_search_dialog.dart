/// 全书搜索对话框：按章节分组的跨文档搜索，点击命中跳转。
///
/// 设计依据：docs/app/ui-sidebar.md §全书搜索、design.md（6px 浮层、
/// 4px 条目、hover 反馈、accent 高亮命中词）。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;
import '../core/book_search.dart';
import '../state/library_controller.dart';
import '../util/debounce.dart';
import 'zz.dart';

/// 打开全书搜索。[onOpen] 收到被点中的命中（对话框已关闭后调用）。
Future<void> showBookSearchDialog(
  BuildContext context, {
  required LibraryController library,
  required void Function(BookSearchHit hit) onOpen,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      alignment: const Alignment(0, -0.4),
      child: _BookSearchPanel(library: library, onOpen: onOpen),
    ),
  );
}

class _BookSearchPanel extends StatefulWidget {
  const _BookSearchPanel({required this.library, required this.onOpen});

  final LibraryController library;
  final void Function(BookSearchHit hit) onOpen;

  @override
  State<_BookSearchPanel> createState() => _BookSearchPanelState();
}

class _BookSearchPanelState extends State<_BookSearchPanel> {
  final TextEditingController _query = TextEditingController();
  final Debouncer _debounce = Debouncer(const Duration(milliseconds: 250));

  List<BookSearchGroup> _groups = const [];
  bool _searching = false;

  /// 已出结果的查询（区分「未搜索」与「无结果」）；乱序结果用它丢弃。
  String _searchedQuery = '';
  int _searchSeq = 0;

  @override
  void dispose() {
    _query.dispose();
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
    final groups = await searchBook(
      notebooks: widget.library.notebooks,
      documentsOf: widget.library.documentsOf,
      query: query,
    );
    if (!mounted || seq != _searchSeq) return; // 已有更新的查询在跑
    setState(() {
      _groups = groups;
      _searchedQuery = query;
      _searching = false;
    });
  }

  void _open(BookSearchHit hit) {
    Navigator.of(context).pop();
    widget.onOpen(hit);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    return SizedBox(
      width: (size.width - 48).clamp(320.0, 640.0),
      height: (size.height - 96).clamp(280.0, 480.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: ZzTextField(
              controller: _query,
              hint: '全书搜索：人名、地名、称呼、设定…',
              autofocus: true,
              onChanged: _onQueryChanged,
            ),
          ),
          Divider(height: 1, color: colors.outline),
          Expanded(child: _results(context)),
        ],
      ),
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
