/// App 装配：MaterialApp、路由、主题选择。
///
/// 视觉方向（2026-08 起）：Notion-inspired design system —— 纸张感页面、
/// 低对比侧栏、克制 hover/selected 状态、内容优先的排版。
library;

import 'package:flutter/material.dart';

import 'core/backup/backup.dart';
import 'core/app_logger.dart';
import 'core/crash_journal.dart';
import 'core/snapshot_history.dart';
import 'core/update.dart';
import 'state/library_controller.dart';
import 'state/settings_controller.dart';
import 'ui/library_home.dart';
import 'ui/shell.dart';
import 'ui/zz.dart' show showZzToast;

/// Design Tokens（单源；UI 层尽量从 Theme / AppColors 获取，避免硬编码）。
abstract final class AppTokens {
  // Notion light
  static const lightPage = Color(0xFFFFFFFF);
  static const lightSidebar = Color(0xFFF7F7F5);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceRaised = Color(0xFFFFFFFF);
  static const lightRowHover = Color(0x0A000000);
  static const lightRowSelected = Color(0x0F000000);
  static const lightTextPrimary = Color(0xFF37352F);
  static const lightTextSecondary = Color(0xFF787774);
  static const lightTextTertiary = Color(0xFF9B9A97);
  static const lightHairline = Color(0x1737352F);
  static const lightAccent = Color(0xFF2383E2);
  static const lightSuccess = Color(0xFF448361);
  static const lightDanger = Color(0xFFE03E3E);
  static const lightCallout = Color(0xFFF7F6F3);

  // Notion dark
  static const darkPage = Color(0xFF191919);
  static const darkSidebar = Color(0xFF202020);
  static const darkSurface = Color(0xFF252525);
  static const darkSurfaceRaised = Color(0xFF2B2B2B);
  static const darkRowHover = Color(0x0EFFFFFF);
  static const darkRowSelected = Color(0x16FFFFFF);
  static const darkTextPrimary = Color(0xDEFFFFFF);
  static const darkTextSecondary = Color(0xFFA3A29E);
  static const darkTextTertiary = Color(0xFF787774);
  static const darkHairline = Color(0x18FFFFFF);
  static const darkAccent = Color(0xFF529CCA);
  static const darkSuccess = Color(0xFF6BAA7F);
  static const darkDanger = Color(0xFFFF7369);
  static const darkCallout = Color(0xFF242424);
}

/// 应用门控：有当前笔记本 → 单书工作区 Shell；否则 → 笔记本管理层 LibraryHome。
///
/// 进入/退出工作区是声明式的（LibraryController.currentNotebook 驱动），
/// 不做 Navigator 栈：点书 openNotebook → 门控切到 Shell；返回 closeNotebook
/// → 门控切回 LibraryHome。
///
/// 同时承载启动自动更新检查的可见化：main.dart 启动后异步 check() 一次，
/// 发现新版时状态切到 available —— 这里监听该状态，弹一次 toast 提示，
/// 用户无需手动进设置点「检查更新」。
class _AppGate extends StatefulWidget {
  const _AppGate({
    required this.library,
    required this.settings,
    this.journal,
    this.logger,
    this.backup,
    this.updateChecker,
    this.snapshots,
  });

  final LibraryController library;
  final SettingsController settings;
  final CrashJournal? journal;
  final AppLogger? logger;
  final BackupManager? backup;
  final UpdateChecker? updateChecker;
  final SnapshotHistory? snapshots;

  @override
  State<_AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<_AppGate> {
  /// 本次启动已提示过新版（避免监听器重复弹）。
  bool _updateToastShown = false;

  @override
  void initState() {
    super.initState();
    widget.updateChecker?.status.addListener(_maybeNotifyUpdate);
    // 启动检查可能先于首帧完成，挂载时直接兜底一次。
    _maybeNotifyUpdate();
  }

  @override
  void dispose() {
    widget.updateChecker?.status.removeListener(_maybeNotifyUpdate);
    super.dispose();
  }

  /// 发现新版（available 态）→ 弹一次 toast，无需用户手动触发检查。
  void _maybeNotifyUpdate() {
    final checker = widget.updateChecker;
    if (checker == null || _updateToastShown) return;
    if (checker.status.value != UpdateStatus.available) return;
    _updateToastShown = true;
    final version = checker.availableVersion.value ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showZzToast(context, '发现新版本 v$version，可在「设置」中更新');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.library,
      builder: (context, _) {
        if (widget.library.currentNotebook != null) {
          return Shell(
            library: widget.library,
            settings: widget.settings,
            journal: widget.journal,
            logger: widget.logger,
            backup: widget.backup,
            updateChecker: widget.updateChecker,
            snapshots: widget.snapshots,
          );
        }
        return LibraryHome(
          library: widget.library,
          settings: widget.settings,
          journal: widget.journal,
          logger: widget.logger,
          backup: widget.backup,
          updateChecker: widget.updateChecker,
        );
      },
    );
  }
}

/// 超出 ColorScheme 承载范围的 token（单源 AppTokens，经 ThemeExtension 下发）。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.sidebar,
    required this.surfaceHover,
    required this.rowSelected,
    required this.surfaceRaised,
    required this.callout,
    required this.textTertiary,
    required this.success,
  });

  final Color sidebar;
  final Color surfaceHover;
  final Color rowSelected;
  final Color surfaceRaised;
  final Color callout;
  final Color textTertiary;
  final Color success;

  @override
  AppColors copyWith({
    Color? sidebar,
    Color? surfaceHover,
    Color? rowSelected,
    Color? surfaceRaised,
    Color? callout,
    Color? textTertiary,
    Color? success,
  }) => AppColors(
    sidebar: sidebar ?? this.sidebar,
    surfaceHover: surfaceHover ?? this.surfaceHover,
    rowSelected: rowSelected ?? this.rowSelected,
    surfaceRaised: surfaceRaised ?? this.surfaceRaised,
    callout: callout ?? this.callout,
    textTertiary: textTertiary ?? this.textTertiary,
    success: success ?? this.success,
  );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      rowSelected: Color.lerp(rowSelected, other.rowSelected, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      callout: Color.lerp(callout, other.callout, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      success: Color.lerp(success, other.success, t)!,
    );
  }
}

AppColors appColorsOf(BuildContext context) =>
    Theme.of(context).extension<AppColors>() ??
    const AppColors(
      sidebar: AppTokens.lightSidebar,
      surfaceHover: AppTokens.lightRowHover,
      rowSelected: AppTokens.lightRowSelected,
      surfaceRaised: AppTokens.lightSurfaceRaised,
      callout: AppTokens.lightCallout,
      textTertiary: AppTokens.lightTextTertiary,
      success: AppTokens.lightSuccess,
    );

abstract final class AppTheme {
  static ThemeData light() => _build(
    brightness: Brightness.light,
    page: AppTokens.lightPage,
    sidebar: AppTokens.lightSidebar,
    surface: AppTokens.lightSurface,
    surfaceRaised: AppTokens.lightSurfaceRaised,
    surfaceHover: AppTokens.lightRowHover,
    rowSelected: AppTokens.lightRowSelected,
    textPrimary: AppTokens.lightTextPrimary,
    textSecondary: AppTokens.lightTextSecondary,
    textTertiary: AppTokens.lightTextTertiary,
    hairline: AppTokens.lightHairline,
    accent: AppTokens.lightAccent,
    success: AppTokens.lightSuccess,
    danger: AppTokens.lightDanger,
    callout: AppTokens.lightCallout,
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    page: AppTokens.darkPage,
    sidebar: AppTokens.darkSidebar,
    surface: AppTokens.darkSurface,
    surfaceRaised: AppTokens.darkSurfaceRaised,
    surfaceHover: AppTokens.darkRowHover,
    rowSelected: AppTokens.darkRowSelected,
    textPrimary: AppTokens.darkTextPrimary,
    textSecondary: AppTokens.darkTextSecondary,
    textTertiary: AppTokens.darkTextTertiary,
    hairline: AppTokens.darkHairline,
    accent: AppTokens.darkAccent,
    success: AppTokens.darkSuccess,
    danger: AppTokens.darkDanger,
    callout: AppTokens.darkCallout,
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color page,
    required Color sidebar,
    required Color surface,
    required Color surfaceRaised,
    required Color surfaceHover,
    required Color rowSelected,
    required Color textPrimary,
    required Color textSecondary,
    required Color textTertiary,
    required Color hairline,
    required Color accent,
    required Color success,
    required Color danger,
    required Color callout,
  }) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: brightness == Brightness.dark
          ? AppTokens.darkPage
          : Colors.white,
      secondary: accent,
      onSecondary: brightness == Brightness.dark
          ? AppTokens.darkPage
          : Colors.white,
      error: danger,
      onError: Colors.white,
      surface: surface,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      outline: hairline,
      outlineVariant: hairline,
      surfaceContainerHighest: surfaceHover,
    );
    return ThemeData(
      useMaterial3: false,
      colorScheme: scheme,
      scaffoldBackgroundColor: page,
      canvasColor: surface,
      cardColor: surfaceRaised,
      dividerColor: hairline,
      extensions: [
        AppColors(
          sidebar: sidebar,
          surfaceHover: surfaceHover,
          rowSelected: rowSelected,
          surfaceRaised: surfaceRaised,
          callout: callout,
          textTertiary: textTertiary,
          success: success,
        ),
      ],
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: surfaceHover,
      // 文本选区：低饱和 accent（Notion 选区观感），光标同 accent。
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.28),
        selectionHandleColor: accent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: hairline),
        ),
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
        contentTextStyle: TextStyle(fontSize: 13, color: textSecondary),
      ),
      fontFamily: null,
      textTheme: const TextTheme().apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      iconTheme: IconThemeData(color: textSecondary, size: 18),
      dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: textSecondary,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          minimumSize: const Size(0, 30),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: textSecondary,
          hoverColor: surfaceHover,
          highlightColor: surfaceHover,
          minimumSize: const Size(28, 28),
          padding: const EdgeInsets.all(4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: brightness == Brightness.dark
            ? surfaceRaised
            : textPrimary,
        contentTextStyle: TextStyle(
          color: brightness == Brightness.dark ? textPrimary : Colors.white,
          fontSize: 13,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surfaceRaised,
        elevation: 4,
        textStyle: TextStyle(color: textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: hairline),
        ),
      ),
    );
  }
}

class ZiZaiApp extends StatelessWidget {
  const ZiZaiApp({
    super.key,
    required this.library,
    required this.settings,
    this.journal,
    this.logger,
    this.backup,
    this.updateChecker,
    this.snapshots,
  });

  final LibraryController library;
  final SettingsController settings;

  /// 崩溃日志（null = 未接线，如测试）。
  final CrashJournal? journal;

  /// 本地诊断日志（null = 未接线，如测试）。
  final AppLogger? logger;

  /// 全量备份引擎（null = 未接线，如测试）。
  final BackupManager? backup;

  /// 更新检查（null = 未接线，如测试）。
  final UpdateChecker? updateChecker;

  /// 单文档版本历史（null = 未接线，如测试）。
  final SnapshotHistory? snapshots;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return MaterialApp(
          title: '字在',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: settings.themeMode,
          home: _AppGate(
            library: library,
            settings: settings,
            journal: journal,
            logger: logger,
            backup: backup,
            updateChecker: updateChecker,
            snapshots: snapshots,
          ),
        );
      },
    );
  }
}
