/// 防抖工具（自动保存 1s 防抖、崩溃日志节流）。
library;

import 'dart:async';

/// 防抖：在 [duration] 内连续调用只执行最后一次。
class Debouncer {
  Debouncer(this.duration);

  final Duration duration;
  Timer? _timer;

  /// 调度一次执行；已有待执行的会取消重排。
  void schedule(void Function() action) {
    _timer?.cancel();
    _timer = Timer(duration, action);
  }

  /// 立即执行并取消待执行的调度（失焦/切换/退出场景）。
  void flush(void Function() action) {
    _timer?.cancel();
    _timer = null;
    action();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
