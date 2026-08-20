import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/writing_session.dart';

void main() {
  group('WritingSession', () {
    /// 在 FakeAsync 内用 getClock 获得与时间同步推进的时钟。
    WritingSession makeSession(
      FakeAsync async, {
      Duration idleTimeout = const Duration(minutes: 5),
    }) =>
        WritingSession(
          idleTimeout: idleTimeout,
          now: async.getClock(DateTime(2025)).now,
        );

    test('初始状态：零字数、非活跃', () {
      fakeAsync((async) {
        final s = makeSession(async);
        expect(s.words, 0);
        expect(s.active, isFalse);
        expect(s.snapshot.duration, Duration.zero);
        expect(s.snapshot.wordsPerHour, 0);
      });
    });

    test('上报正向增量后字数累计、进入活跃', () {
      fakeAsync((async) {
        final s = makeSession(async);
        s.onWordsWritten(10);
        expect(s.words, 10);
        expect(s.active, isTrue);
        s.onWordsWritten(5);
        expect(s.words, 15);
      });
    });

    test('非正数增量被忽略', () {
      fakeAsync((async) {
        final s = makeSession(async);
        s.onWordsWritten(10);
        s.onWordsWritten(0);
        s.onWordsWritten(-3);
        expect(s.words, 10);
      });
    });

    test('reset 清空所有状态', () {
      fakeAsync((async) {
        final s = makeSession(async);
        s.onWordsWritten(20);
        s.reset();
        expect(s.words, 0);
        expect(s.active, isFalse);
        expect(s.snapshot.duration, Duration.zero);
      });
    });

    test('空闲超时后变为非活跃', () {
      fakeAsync((async) {
        final s = makeSession(async, idleTimeout: const Duration(minutes: 5));
        s.onWordsWritten(10);
        expect(s.active, isTrue);

        // 还没超时
        async.elapse(const Duration(minutes: 3));
        expect(s.active, isTrue);

        // 超时
        async.elapse(const Duration(minutes: 3));
        expect(s.active, isFalse);
        expect(s.words, 10); // 字数不丢
      });
    });

    test('空闲后快照时长冻结在边界', () {
      fakeAsync((async) {
        final s = makeSession(async, idleTimeout: const Duration(minutes: 5));
        s.onWordsWritten(10);
        // 活跃 2 分钟（快照实时反映）
        async.elapse(const Duration(minutes: 2));
        expect(s.snapshot.duration.inMinutes, 2);

        // 空闲 6 分钟（超过 5 分钟阈值）
        async.elapse(const Duration(minutes: 6));
        expect(s.active, isFalse);
        // 时长冻结在 _lastActivity(0) + idleTimeout(5) = 5 分钟
        expect(s.snapshot.duration.inMinutes, 5);

        // 继续空闲，时长不再增长
        async.elapse(const Duration(minutes: 30));
        expect(s.snapshot.duration.inMinutes, 5);
      });
    });

    test('空闲后续接：字数累计、新活跃段', () {
      fakeAsync((async) {
        final s = makeSession(async, idleTimeout: const Duration(minutes: 5));
        s.onWordsWritten(10);
        async.elapse(const Duration(minutes: 10)); // 超时
        expect(s.active, isFalse);

        s.onWordsWritten(5); // 续接
        expect(s.active, isTrue);
        expect(s.words, 15);
      });
    });

    test('wordsPerHour 基于活跃时长计算', () {
      fakeAsync((async) {
        final s = makeSession(async, idleTimeout: const Duration(hours: 1));
        s.onWordsWritten(100);
        // 模拟 30 分钟活跃写作（期间未超时）
        async.elapse(const Duration(minutes: 30));
        expect(s.active, isTrue);
        // 100 字 / 30 分钟 * 60 = 200 字/小时
        expect(s.snapshot.wordsPerHour, 200);
      });
    });

    test('不足 1 分钟时 wordsPerHour 为 0', () {
      fakeAsync((async) {
        final s = makeSession(async, idleTimeout: const Duration(hours: 1));
        s.onWordsWritten(5);
        async.elapse(const Duration(seconds: 10));
        expect(s.snapshot.wordsPerHour, 0);
      });
    });

    test('通知监听器：写入和重置触发', () {
      fakeAsync((async) {
        final s = makeSession(async, idleTimeout: const Duration(minutes: 5));
        var notifications = 0;
        s.addListener(() => notifications++);

        s.onWordsWritten(5);
        expect(notifications, 1);

        // 空闲超时不触发通知（无 Timer）；用 snapshot 惰性读取
        async.elapse(const Duration(minutes: 10));
        expect(notifications, 1);
        expect(s.active, isFalse);

        s.reset();
        expect(notifications, 2);
      });
    });

    test('续接后总时长 = 旧段冻结 + 新段活跃', () {
      fakeAsync((async) {
        final s = makeSession(async, idleTimeout: const Duration(minutes: 5));
        s.onWordsWritten(50);
        // 活跃 10 分钟（每分钟续写保持活跃，_lastActivity 不断更新）
        for (var i = 0; i < 10; i++) {
          async.elapse(const Duration(minutes: 1));
          s.onWordsWritten(1);
        }
        expect(s.active, isTrue);
        expect(s.snapshot.duration.inMinutes, 10);

        // 空闲 6 分钟后超时
        async.elapse(const Duration(minutes: 6));
        expect(s.active, isFalse);
        // _lastActivity 在 t=10，冻结点 = 10 + 5 = 15
        // 时长 = 15 - 0 = 15 分钟（段开始 t=0）
        expect(s.snapshot.duration.inMinutes, 15);

        // 续接后再写 20 分钟
        s.onWordsWritten(30);
        for (var i = 0; i < 20; i++) {
          async.elapse(const Duration(minutes: 1));
          s.onWordsWritten(1);
        }
        // 总时长 = 15（旧段冻结）+ 20（新段活跃）= 35 分钟
        expect(s.snapshot.duration.inMinutes, 35);
        expect(s.words, 50 + 10 + 30 + 20);
      });
    });
  });

  group('formatSessionDuration', () {
    test('不足 1 分钟显示 <1分', () {
      expect(formatSessionDuration(const Duration(seconds: 30)), '<1分');
    });
    test('分钟', () {
      expect(formatSessionDuration(const Duration(minutes: 12)), '12分');
    });
    test('小时+分钟', () {
      expect(formatSessionDuration(const Duration(minutes: 83)), '1时23分');
    });
    test('整小时', () {
      expect(formatSessionDuration(const Duration(hours: 2)), '2时0分');
    });
  });
}
