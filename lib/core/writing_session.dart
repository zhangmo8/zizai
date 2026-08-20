/// 写作会话追踪：本次写作的字数、时长、速度。
///
/// 设计依据：用户需求「写作会话统计」——除今日字数外，显示本次新增字数、
/// 写作时长、当前速度（字/小时）。统计应鼓励作者，不做红点/任务系统。
///
/// 会话在首次输入时开始；长时间空闲（[idleTimeout]）后自动暂停。
/// 空闲后再次输入会续接同一会话（字数累计、时长只计活跃段）。
///
/// 无 Timer：空闲判定在 [snapshot] / [active] 中惰性计算，
/// 避免长生命周期 Timer 在测试中遗留。UI 层用定时刷新驱动显示更新。
library;

import 'package:flutter/foundation.dart';

/// 空闲超时：超过此时长无输入，活跃段暂停（时长冻结）。
const Duration _idleTimeout = Duration(minutes: 10);

/// 写作会话快照（供 UI 读取的不可变视图）。
class WritingSessionSnapshot {
  const WritingSessionSnapshot({
    this.words = 0,
    this.duration = Duration.zero,
    this.active = false,
  });

  /// 本次会话新增字数（仅正向增量，删除不倒扣）。
  final int words;

  /// 写作时长（仅活跃段累计，不含空闲）。
  final Duration duration;

  /// 会话是否正在活跃（用户最近有输入）。
  final bool active;

  /// 当前速度（字/小时）；不足 1 分钟返回 0。
  int get wordsPerHour {
    final minutes = duration.inMinutes;
    if (minutes < 1) return 0;
    return (words * 60 / minutes).round();
  }

  @override
  String toString() =>
      'WritingSessionSnapshot(words=$words, duration=$duration, '
      'active=$active, wph=$wordsPerHour)';
}

/// 写作会话追踪器。
///
/// 由 [LibraryController] 持有，编辑器在文档变更时调用 [onWordsWritten]
/// 上报正向字数增量；状态栏订阅重建会话条。文档切换时 [reset]。
///
/// [now] 可注入时钟以便测试。
class WritingSession extends ChangeNotifier {
  WritingSession({
    this.idleTimeout = _idleTimeout,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 空闲超时（可注入以便测试）。
  final Duration idleTimeout;

  /// 时钟函数（可注入以便测试）。
  final DateTime Function() _now;

  /// 当前活跃段的开始时间（null = 无活跃段）。
  DateTime? _segmentStart;

  /// 最后一次输入时间。
  DateTime? _lastActivity;

  /// 已冻结的活跃段时长（不含当前进行中的段）。
  Duration _accumulated = Duration.zero;

  /// 本次会话新增字数。
  int _words = 0;
  int get words => _words;

  /// 会话是否正在活跃（最后一次输入在 [idleTimeout] 内）。
  bool get active {
    if (_segmentStart == null || _lastActivity == null) return false;
    return _now().difference(_lastActivity!) < idleTimeout;
  }

  /// 当前快照：实时计算时长（活跃段到当前，或冻结到空闲边界）。
  WritingSessionSnapshot get snapshot {
    final now = _now();
    var duration = _accumulated;
    if (_segmentStart != null && _lastActivity != null) {
      final idleFor = now.difference(_lastActivity!);
      if (idleFor < idleTimeout) {
        // 仍在活跃段：时长 = 当前 - 段开始
        duration += now.difference(_segmentStart!);
      } else {
        // 已空闲超时：段在 _lastActivity + idleTimeout 处冻结
        final segmentEnd = _lastActivity!.add(idleTimeout);
        duration += segmentEnd.difference(_segmentStart!);
      }
    }
    return WritingSessionSnapshot(
      words: _words,
      duration: duration,
      active: active,
    );
  }

  /// 编辑器上报新增字数（仅正向增量）。非正数忽略。
  ///
  /// 若上次活跃段已超空闲阈值，先冻结旧段再开新段。
  void onWordsWritten(int delta) {
    if (delta <= 0) return;
    final now = _now();
    if (_segmentStart != null && _lastActivity != null) {
      final idleFor = now.difference(_lastActivity!);
      if (idleFor >= idleTimeout) {
        // 旧段冻结，开新段
        final segmentEnd = _lastActivity!.add(idleTimeout);
        _accumulated += segmentEnd.difference(_segmentStart!);
        _segmentStart = now;
      }
    } else {
      _segmentStart ??= now;
    }
    _lastActivity = now;
    _words += delta;
    notifyListeners();
  }

  /// 重置会话（切换文档时调用）。
  void reset() {
    _segmentStart = null;
    _lastActivity = null;
    _accumulated = Duration.zero;
    _words = 0;
    notifyListeners();
  }
}

/// 时长格式化：`12分` / `1时23分` / `<1分`。
String formatSessionDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0) return '$h时$m分';
  if (m > 0) return '$m分';
  return '<1分';
}
