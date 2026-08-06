/// App 装配：MaterialApp、路由、主题选择。
///
/// 设计依据：docs/app/style.md（Design Tokens → ThemeData，shell-001 接线）、
/// docs/app/ui-shell.md（主界面壳）。
///
/// 视觉方向（2026-08 起）：macOS 26 / iOS 26 Liquid Glass —— 冷调中性色、
/// 通透毛玻璃、Cupertino 控件；不使用 Material 3 组件语言。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'core/backup/backup.dart';
import 'core/crash_journal.dart';
import 'core/update.dart';
import 'state/library_controller.dart';
import 'state/settings_controller.dart';
import 'ui/shell.dart';

/// Design Tokens（单源，映射 style.md §3 色彩系统；代码不允许硬编码颜色）。
/// macOS 26 / iOS 26 冷调中性色（Apple system colors）。
abstract final class AppTokens {
  // 浅色
  static const lightBg = Color(0xFFF5F5F7);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightSurfaceHover = Color(0x14000000); // 黑 8%（hover/选中底）
  static const lightTextPrimary = Color(0xFF1D1D1F);
  static const lightTextSecondary = Color(0xFF6E6E73);
  static const lightTextTertiary = Color(0xFF86868B);
  static const lightHairline = Color(0x1A000000); // 黑 10%（1px 分隔）
  static const lightAccent = Color(0xFF007AFF); // iOS systemBlue
  static const lightSuccess = Color(0xFF34C759); // iOS systemGreen
  static const lightDanger = Color(0xFFFF3B30); // iOS systemRed

  // 深色（macOS 26 深色不是纯黑：深灰底 + 白微透玻璃，保留层次与色彩）
  static const darkBg = Color(0xFF1C1C1E);
  static const darkBgTop = Color(0xFF242426); // 窗口顶渐变微亮
  static const darkSurface = Color(0xFFFFFFFF);
  static const darkSurfaceHover = Color(0x1FFFFFFF); // 白 12%
  static const darkTextPrimary = Color(0xFFF5F5F7);
  static const darkTextSecondary = Color(0xFFA1A1A6);
  static const darkTextTertiary = Color(0xFF6E6E73);
  static const darkHairline = Color(0x1FFFFFFF); // 白 12%
  static const darkAccent = Color(0xFF0A84FF);
  static const darkSuccess = Color(0xFF30D158);
  static const darkDanger = Color(0xFFFF453A);
}

/// 超出 ColorScheme 承载范围的 token（单源 AppTokens，经 ThemeExtension 下发）。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.surfaceHover,
    required this.textTertiary,
    required this.success,
  });

  final Color surfaceHover;
  final Color textTertiary;
  final Color success;

  @override
  AppColors copyWith({Color? surfaceHover, Color? textTertiary, Color? success}) =>
      AppColors(
        surfaceHover: surfaceHover ?? this.surfaceHover,
        textTertiary: textTertiary ?? this.textTertiary,
        success: success ?? this.success,
      );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      success: Color.lerp(success, other.success, t)!,
    );
  }
}

AppColors appColorsOf(BuildContext context) =>
    Theme.of(context).extension<AppColors>() ??
    // 兜底（测试等无主题场景）：跟随亮色 token。
    const AppColors(
      surfaceHover: Color(0x14000000),
      textTertiary: Color(0xFF86868B),
      success: Color(0xFF34C759),
    );

abstract final class AppTheme {
  static ThemeData light() => _build(
        brightness: Brightness.light,
        bg: AppTokens.lightBg,
        surface: AppTokens.lightSurface,
        surfaceHover: AppTokens.lightSurfaceHover,
        textPrimary: AppTokens.lightTextPrimary,
        textSecondary: AppTokens.lightTextSecondary,
        textTertiary: AppTokens.lightTextTertiary,
        hairline: AppTokens.lightHairline,
        accent: AppTokens.lightAccent,
        success: AppTokens.lightSuccess,
        danger: AppTokens.lightDanger,
      );

  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        bg: AppTokens.darkBg,
        surface: AppTokens.darkSurface,
        surfaceHover: AppTokens.darkSurfaceHover,
        textPrimary: AppTokens.darkTextPrimary,
        textSecondary: AppTokens.darkTextSecondary,
        textTertiary: AppTokens.darkTextTertiary,
        hairline: AppTokens.darkHairline,
        accent: AppTokens.darkAccent,
        success: AppTokens.darkSuccess,
        danger: AppTokens.darkDanger,
      );

  /// Cupertino 控件主题（与 Material 主题同源 token）。
  static CupertinoThemeData cupertino(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return CupertinoThemeData(
      brightness: brightness,
      primaryColor: dark ? AppTokens.darkAccent : AppTokens.lightAccent,
      scaffoldBackgroundColor: dark ? AppTokens.darkBg : AppTokens.lightBg,
      textTheme: CupertinoTextThemeData(
        textStyle: TextStyle(
          fontSize: 13,
          color: dark ? AppTokens.darkTextPrimary : AppTokens.lightTextPrimary,
        ),
      ),
    );
  }

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color surfaceHover,
    required Color textPrimary,
    required Color textSecondary,
    required Color textTertiary,
    required Color hairline,
    required Color accent,
    required Color success,
    required Color danger,
  }) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: surface,
      secondary: accent,
      onSecondary: surface,
      error: danger,
      onError: surface,
      surface: bg,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      outline: hairline,
      outlineVariant: hairline,
      surfaceContainerHighest: surfaceHover,
    );
    return ThemeData(
      useMaterial3: false,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      dividerColor: hairline,
      extensions: [
        AppColors(
          surfaceHover: surfaceHover,
          textTertiary: textTertiary,
          success: success,
        ),
      ],
      // Apple 无 Ink 水波纹：点击/悬停只改底色，不做涟漪。
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: surfaceHover,
      textTheme: const TextTheme().apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: textPrimary,
        contentTextStyle: TextStyle(color: bg, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
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
    this.backup,
    this.updateChecker,
  });

  final LibraryController library;
  final SettingsController settings;

  /// 崩溃日志（null = 未接线，如测试）。
  final CrashJournal? journal;

  /// 全量备份引擎（null = 未接线，如测试）。
  final BackupManager? backup;

  /// 更新检查（null = 未接线，如测试）。
  final UpdateChecker? updateChecker;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final dark = settings.themeMode == ThemeMode.dark ||
            (settings.themeMode == ThemeMode.system &&
                MediaQuery.platformBrightnessOf(context) == Brightness.dark);
        return MaterialApp(
          title: '字在',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: settings.themeMode,
          builder: (context, child) => CupertinoTheme(
            data: AppTheme.cupertino(dark ? Brightness.dark : Brightness.light),
            child: child!,
          ),
          home: Shell(
              library: library,
              settings: settings,
              journal: journal,
              backup: backup,
              updateChecker: updateChecker),
        );
      },
    );
  }
}
