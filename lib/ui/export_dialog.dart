/// 整书导出对话框：范围/格式/排版选项 + 导出动作。
///
/// 设计依据：docs/app/ui-settings.md §导出、design.md（下拉选择、
/// 开关、primary 按钮 busy 态、toast 结果反馈）、
/// docs/app/README.md §8（桌面保存对话框 / Android 系统分享）。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app.dart' show appColorsOf;
import '../core/export.dart';
import '../core/models.dart';
import '../state/library_controller.dart';
import '../util/platform.dart';
import 'zz.dart';

/// 单文件导出实现（测试可注入）；返回 false = 用户取消。
typedef SaveBookTextHandler =
    Future<bool> Function(String suggestedName, String text);

/// 每章一文件导出实现（测试可注入）；返回 false = 用户取消。
typedef SaveBookFilesHandler = Future<bool> Function(List<BookExportFile> files);

enum _BookFormat { txt, markdown, markdownPerChapter }

/// 打开整书导出对话框。
Future<void> showBookExportDialog(
  BuildContext context, {
  required LibraryController library,
  SaveBookTextHandler? saveText,
  SaveBookFilesHandler? saveFiles,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: _BookExportPanel(
        library: library,
        saveText: saveText ?? _defaultSaveText,
        saveFiles: saveFiles ?? _defaultSaveFiles,
      ),
    ),
  );
}

Future<bool> _defaultSaveText(String suggestedName, String text) async {
  if (isAndroidPlatform) {
    await SharePlus.instance.share(ShareParams(text: text));
    return true;
  }
  final loc = await getSaveLocation(suggestedName: suggestedName);
  if (loc == null) return false;
  await File(loc.path).writeAsString(text);
  return true;
}

Future<bool> _defaultSaveFiles(List<BookExportFile> files) async {
  final dir = await getDirectoryPath();
  if (dir == null) return false;
  for (final file in files) {
    await File(
      '$dir${Platform.pathSeparator}${file.fileName}',
    ).writeAsString(file.content);
  }
  return true;
}

class _BookExportPanel extends StatefulWidget {
  const _BookExportPanel({
    required this.library,
    required this.saveText,
    required this.saveFiles,
  });

  final LibraryController library;
  final SaveBookTextHandler saveText;
  final SaveBookFilesHandler saveFiles;

  @override
  State<_BookExportPanel> createState() => _BookExportPanelState();
}

class _BookExportPanelState extends State<_BookExportPanel> {
  /// [_kScopeAll] = 全书；否则为单个笔记本 id。
  String _scope = _kScopeAll;
  static const _kScopeAll = 'all';
  _BookFormat _format = _BookFormat.txt;
  bool _numberChapters = true;
  bool _indentParagraphs = true;
  bool _blankLine = true;
  bool _exporting = false;

  List<Notebook> get _notebooks {
    final all = widget.library.notebooks;
    if (_scope == _kScopeAll) return all;
    final picked = [for (final nb in all) if (nb.id == _scope) nb];
    // 所选笔记本可能已被删除，回退全书。
    return picked.isEmpty ? all : picked;
  }

  BookExportOptions get _options => BookExportOptions(
    numberChapters: _numberChapters,
    indentParagraphs: _indentParagraphs,
    blankLineBetweenParagraphs: _blankLine,
  );

  String get _suggestedBase {
    final notebooks = _notebooks;
    return safeFileName(notebooks.length == 1 ? notebooks.single.name : '全书');
  }

  Future<void> _export() async {
    final notebooks = _notebooks;
    final documents = [
      for (final nb in notebooks) ...widget.library.documentsOf(nb.id),
    ];
    if (documents.isEmpty) {
      showZzToast(context, '所选范围内没有章节', error: true);
      return;
    }
    setState(() => _exporting = true);
    try {
      final bool done;
      switch (_format) {
        case _BookFormat.txt:
          done = await widget.saveText(
            '$_suggestedBase.txt',
            exportBookPlainText(notebooks, documents, options: _options),
          );
        case _BookFormat.markdown:
          done = await widget.saveText(
            '$_suggestedBase.md',
            exportBookMarkdown(notebooks, documents, options: _options),
          );
        case _BookFormat.markdownPerChapter:
          done = await widget.saveFiles(
            exportBookMarkdownFiles(notebooks, documents, options: _options),
          );
      }
      if (!mounted) return;
      if (done) {
        Navigator.of(context).pop();
        showZzToast(context, '已导出 ${documents.length} 章');
      }
    } catch (_) {
      if (mounted) showZzToast(context, '导出失败，请稍后重试', error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final notebooks = widget.library.notebooks;
    final scopeNotebooks = _notebooks;
    final scopeLabel = _scope == _kScopeAll || scopeNotebooks.length != 1
        ? '全书（${notebooks.length} 个笔记本）'
        : scopeNotebooks.single.name;
    final txt = _format == _BookFormat.txt;
    return SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Text(
              '导出整本书',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Divider(height: 1, color: colors.outline),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Column(
              children: [
                _row(
                  '范围',
                  ZzSelect<String>(
                    value: _scope,
                    display: scopeLabel,
                    options: [
                      (label: '全书', value: _kScopeAll),
                      for (final nb in notebooks)
                        (label: nb.name, value: nb.id),
                    ],
                    onChanged: (v) => setState(() => _scope = v),
                  ),
                ),
                _row(
                  '格式',
                  ZzSelect<_BookFormat>(
                    value: _format,
                    display: switch (_format) {
                      _BookFormat.txt => 'TXT 单文件',
                      _BookFormat.markdown => 'Markdown 单文件',
                      _BookFormat.markdownPerChapter => 'Markdown · 每章一个文件',
                    },
                    options: [
                      (label: 'TXT 单文件', value: _BookFormat.txt),
                      (label: 'Markdown 单文件', value: _BookFormat.markdown),
                      // Android 走系统分享，装不下一个目录的多文件。
                      if (!isAndroidPlatform)
                        (
                          label: 'Markdown · 每章一个文件',
                          value: _BookFormat.markdownPerChapter,
                        ),
                    ],
                    onChanged: (v) => setState(() => _format = v),
                  ),
                ),
                _row(
                  '章节自动编号',
                  ZzSwitch(
                    value: _numberChapters,
                    onChanged: (v) => setState(() => _numberChapters = v),
                  ),
                  description: '标题前加「第 X 章」；已带编号的标题不重复加',
                ),
                if (txt)
                  _row(
                    '段首缩进',
                    ZzSwitch(
                      value: _indentParagraphs,
                      onChanged: (v) => setState(() => _indentParagraphs = v),
                    ),
                    description: '每段开头两个全角空格',
                  ),
                if (txt)
                  _row(
                    '段间空行',
                    ZzSwitch(
                      value: _blankLine,
                      onChanged: (v) => setState(() => _blankLine = v),
                    ),
                    description: '网文平台常用排版',
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 12, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ZzButton.link(
                  label: '取消',
                  onPressed: _exporting
                      ? null
                      : () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 4),
                ZzButton.primary(
                  label: '导出',
                  busy: _exporting,
                  onPressed: _exporting ? null : _export,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, Widget control, {String? description}) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 13, color: colors.onSurface),
                ),
                if (description != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: appColors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          control,
        ],
      ),
    );
  }
}
