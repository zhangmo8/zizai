/// 「针对这本书的设置」对话框：本书的写作目标 + 段落缩进 + 分卷。
///
/// 设计依据：需求「将【写作】设置拆进针对当前这本书的设置」——写作目标与
/// 段落缩进从全局设置页迁到这里；分卷为本书独立开关 + 每卷章数（视觉分组，
/// 不动库）。全局设置页不再含「写作」分类。
library;

import 'package:flutter/material.dart';

import '../app.dart' show appColorsOf;
import '../core/models.dart';
import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import 'zz.dart';

class BookSettingsDialog extends StatefulWidget {
  const BookSettingsDialog({
    super.key,
    required this.notebook,
    required this.library,
    required this.settings,
    this.autoFocusGoal = false,
  });

  final Notebook notebook;
  final LibraryController library;
  final SettingsController settings;

  /// 打开时聚焦「每日目标字数」（状态栏今日进度点击入口）。
  final bool autoFocusGoal;

  @override
  State<BookSettingsDialog> createState() => _BookSettingsDialogState();
}

class _BookSettingsDialogState extends State<BookSettingsDialog> {
  late final TextEditingController _goalController = TextEditingController();
  late final TextEditingController _volumeController = TextEditingController();
  final FocusNode _goalFocus = FocusNode();
  final FocusNode _volumeFocus = FocusNode();

  String get _notebookId => widget.notebook.id;

  @override
  void initState() {
    super.initState();
    _goalController.text =
        widget.settings.goalForNotebook(_notebookId).words.toString();
    _volumeController.text =
        widget.settings.volumeForNotebook(_notebookId).chapters.toString();
    if (widget.autoFocusGoal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _goalFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _goalController.dispose();
    _volumeController.dispose();
    _goalFocus.dispose();
    _volumeFocus.dispose();
    super.dispose();
  }

  void _setGoal(int words) =>
      widget.settings.updateNotebookGoal(_notebookId, words: words);

  void _setVolumeChapters(int chapters) =>
      widget.settings.setVolumeForNotebook(_notebookId, chapters: chapters);

  @override
  Widget build(BuildContext context) {
    final notebook = widget.notebook;
    final settings = widget.settings;
    return Dialog(
      child: SizedBox(
        width: 460,
        child: ListenableBuilder(
          listenable: settings,
          builder: (context, _) {
            final goal = settings.goalForNotebook(_notebookId);
            final volume = settings.volumeForNotebook(_notebookId);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '这本书的设置 · ${notebook.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Group(
                          label: '写作目标',
                          children: [
                            _row(
                              '启用今日目标',
                              ZzSwitch(
                                value: goal.enabled,
                                onChanged: (enabled) =>
                                    widget.settings.updateNotebookGoal(
                                  _notebookId,
                                  enabled: enabled,
                                ),
                              ),
                              description: '关闭后不在状态栏和沉浸模式显示',
                            ),
                            if (goal.enabled)
                              _row(
                                '每日目标字数',
                                _numberField(
                                  controller: _goalController,
                                  focusNode: _goalFocus,
                                  hint: '100–50000',
                                  onSubmit: (v) {
                                    final n = int.tryParse(v.trim());
                                    if (n != null && n >= 100 && n <= 50000) {
                                      _setGoal(n);
                                    }
                                  },
                                ),
                                description: '只计入这本书今天新增的文字',
                              ),
                          ],
                        ),
                        _Group(
                          label: '段落缩进',
                          children: [
                            _row(
                              '行首自动缩进',
                              ZzSwitch(
                                value:
                                    settings.indentForNotebook(_notebookId),
                                onChanged: (v) => widget.settings
                                    .setIndentForNotebook(_notebookId, v),
                              ),
                              description: '新段落行首自动空两个全角空格',
                            ),
                          ],
                        ),
                        _Group(
                          label: '分卷',
                          children: [
                            _row(
                              '启用分卷',
                              ZzSwitch(
                                value: volume.enabled,
                                onChanged: (enabled) =>
                                    widget.settings.setVolumeForNotebook(
                                  _notebookId,
                                  enabled: enabled,
                                ),
                              ),
                              description: '开启后按每卷章数在目录里拆分为卷',
                            ),
                            if (volume.enabled)
                              _row(
                                '每卷章数',
                                _numberField(
                                  controller: _volumeController,
                                  focusNode: _volumeFocus,
                                  hint: '1–500',
                                  onSubmit: (v) {
                                    final n = int.tryParse(v.trim());
                                    if (n != null && n >= 1 && n <= 500) {
                                      _setVolumeChapters(n);
                                    }
                                  },
                                ),
                                description: '第 1~N 章为第一卷，之后每 N 章一卷',
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(String label, Widget control, {String? description}) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurface,
                  ),
                ),
              ),
              control,
            ],
          ),
          if (description != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: appColors.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _numberField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hint,
    required ValueChanged<String> onSubmit,
  }) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return SizedBox(
      width: 140,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.right,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          filled: true,
          fillColor: appColors.callout,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: colors.outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: BorderSide(color: colors.primary),
          ),
        ),
        onSubmitted: onSubmit,
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appColors = appColorsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 4),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: appColors.textTertiary,
            ),
          ),
        ),
        Divider(color: colors.outline, height: 1),
        ...children,
      ],
    );
  }
}
