/// IME 组合状态追踪：防止拼音输入组合阶段误触快捷键/自动保存。
///
/// 中文输入法组合阶段（拼音未确认）会产生中间文档变更和按键事件，
/// 此时不应触发保存、字数统计刷新或全局快捷键。编辑器在组合区间变化时
/// 更新此状态，全局快捷键处理器和编辑器变更回调读取它做防护。
library;

import 'package:flutter/foundation.dart';

/// 全局 IME 组合状态。
final ValueNotifier<bool> imeComposing = ValueNotifier<bool>(false);

/// 当前是否处于 IME 组合阶段。
bool get isImeComposing => imeComposing.value;
