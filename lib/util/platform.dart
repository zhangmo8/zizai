/// 平台差异工具（docs/app/README.md §8）。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 测试注入：非 null 时覆盖桌面平台判定（CI 跑在 Linux 上，原生判定
/// 恒为桌面，移动端分支无法被 widget 测试覆盖——白屏回归的教训）。
bool? debugIsDesktopPlatformOverride;

/// 是否为桌面平台（macOS / Windows / Linux）。
bool get isDesktopPlatform =>
    debugIsDesktopPlatformOverride ??
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// 是否为 macOS。
bool get isMacOS => !kIsWeb && Platform.isMacOS;

/// 是否为 Windows。
bool get isWindows => !kIsWeb && Platform.isWindows;

/// 是否为 Android。
bool get isAndroidPlatform => !kIsWeb && Platform.isAndroid;
