/// 主界面壳：侧边栏区域 + 编辑器区 + 状态栏，宽度自适应切换形态。
///
/// 设计依据：docs/app/ui-shell.md（Region Layout / State Variants /
/// Interactions）、docs/app/style.md（§3 tokens、§5 尺寸、§9 组件样式）。
/// 侧边栏文档树内容由 side-002 落地；此处为壳的侧边栏区域与空态引导。
library;

import 'package:flutter/material.dart';

import '../state/library_controller.dart';
import '../state/settings_controller.dart';
import 'status_bar.dart';

const double _desktopSidebarWidth = 240;
const double _androidDrawerWidth = 360;
const double _desktopBreakpoint = 800;

class Shell extends StatelessWidget {
  const Shell({super.key, required this.library, required this.settings});

  final LibraryController library;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([library, settings]),
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= _desktopBreakpoint;
            final editor = _EditorArea(library: library, settings: settings);
            final sidebar = _SidebarRegion(
              library: library,
              width: desktop ? _desktopSidebarWidth : _androidDrawerWidth,
            );
            if (desktop) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  sidebar,
                  const VerticalDivider(width: 1),
                  Expanded(child: editor),
                ],
              );
            }
            // Android 形态：Drawer 左滑入（含遮罩），编辑器全宽。
            return Scaffold(
              drawer: Drawer(width: _androidDrawerWidth, child: sidebar),
              body: editor,
            );
          },
        );
      },
    );
  }
}

/// 侧边栏区域（壳级；文档树 CRUD 归 side-002）。
class _SidebarRegion extends StatelessWidget {
  const _SidebarRegion({required this.library, required this.width});

  final LibraryController library;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final notebooks = library.notebooks;

    return Container(
      width: width,
      color: colors.surface,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '笔记本',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: notebooks.isEmpty
                ? _EmptyLibrary(library: library)
                : ListView.builder(
                    itemCount: notebooks.length,
                    itemBuilder: (context, i) {
                      final nb = notebooks[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            Icon(Icons.folder_outlined,
                                size: 16, color: colors.onSurfaceVariant),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                nb.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colors.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 空库引导（ui-shell State Variants：空库 → 侧边栏「新建笔记本」按钮）。
class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.library});

  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined, size: 24, color: colors.outline),
            const SizedBox(height: 8),
            Text(
              '还没有笔记本',
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => library.createNotebook('未命名笔记本'),
              child: const Text('新建笔记本'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑器区（edit-003 用 Quill 编辑器替换内容占位）。
class _EditorArea extends StatelessWidget {
  const _EditorArea({required this.library, required this.settings});

  final LibraryController library;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Expanded(
          child: library.loading
              ? const Center(child: Text('载入中…'))
              : library.currentDocument == null
                  ? Center(
                      child: Text(
                        '从这里开始写…',
                        style: TextStyle(
                          fontSize: 16,
                          fontStyle: FontStyle.italic,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Center(
                      child: Text(
                        library.currentDocument!.title,
                        style: TextStyle(fontSize: 24, color: colors.onSurface),
                      ),
                    ),
        ),
        StatusBar(library: library, settings: settings),
      ],
    );
  }
}
