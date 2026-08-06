/// App 装配：MaterialApp、路由、主题选择。
///
/// 设计依据：docs/app/style.md（Design Tokens → ThemeData，shell-001 接线）、
/// docs/app/ui-shell.md（主界面壳）。
library;

import 'package:flutter/material.dart';

import 'core/crash_journal.dart';
import 'core/sync/client.dart';
import 'state/library_controller.dart';
import 'state/settings_controller.dart';
import 'ui/shell.dart';

/// Design Tokens（单源，映射 style.md §3 色彩系统；代码不允许硬编码颜色）。
abstract final class AppTokens {
  // 浅色
  static const lightBg = Color(0xFFF7F6F3);
  static const lightSurface = Color(0xFFFCFBF9);
  static const lightSurfaceHover = Color(0xFFF0EEEA);
  static const lightTextPrimary = Color(0xFF1F1E1C);
  static const lightTextSecondary = Color(0xFF6B6863);
  static const lightTextTertiary = Color(0xFFA8A49D);
  static const lightHairline = Color(0xFFE4E1DB);
  static const lightAccent = Color(0xFF41695A);
  static const lightSuccess = Color(0xFF4A7A5C);
  static const lightDanger = Color(0xFFB0564C);

  // 深色
  static const darkBg = Color(0xFF1B1B19);
  static const darkSurface = Color(0xFF21211F);
  static const darkSurfaceHover = Color(0xFF2A2A27);
  static const darkTextPrimary = Color(0xFFE8E6E1);
  static const darkTextSecondary = Color(0xFFA29E96);
  static const darkTextTertiary = Color(0xFF6E6A63);
  static const darkHairline = Color(0xFF34332F);
  static const darkAccent = Color(0xFF8FAD9E);
  static const darkSuccess = Color(0xFF7FA893);
  static const darkDanger = Color(0xFFC97A70);
}

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
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(
      primary: accent,
      surface: bg,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      outline: hairline,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      dividerColor: hairline,
      textTheme: const TextTheme().apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
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
    this.syncClient,
  });

  final LibraryController library;
  final SettingsController settings;

  /// 崩溃日志（null = 未接线，如测试）。
  final CrashJournal? journal;

  /// 同步引擎（null = 未接线，如测试）。
  final SyncClient? syncClient;

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
          home: Shell(
              library: library,
              settings: settings,
              journal: journal,
              syncClient: syncClient),
        );
      },
    );
  }
}
