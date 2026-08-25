/// 平台差异工具（docs/app/README.md §8）。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 是否为桌面平台（macOS / Windows / Linux）。
bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// 是否为 macOS。
bool get isMacOS => !kIsWeb && Platform.isMacOS;

/// 是否为 Windows。
bool get isWindows => !kIsWeb && Platform.isWindows;

/// 是否为 Android。
bool get isAndroidPlatform => !kIsWeb && Platform.isAndroid;
