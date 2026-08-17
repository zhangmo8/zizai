import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/models.dart';
import 'package:zi_zai/core/snapshot_history.dart';

void main() {
  late Directory tmp;
  late SnapshotHistory history;

  Document doc(
    String id, {
    String title = '章',
    String content = '[{"insert":"正文"}]',
    int words = 2,
  }) => Document(
    id: id,
    notebookId: 'n1',
    title: title,
    content: content,
    words: words,
    position: 0,
    createdAt: 0,
    updatedAt: 0,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zz-snap-');
    history = SnapshotHistory(rootPath: tmp.path);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('create/list', () {
    test('创建后可列出，新的在前', () async {
      final base = DateTime(2026, 8, 1, 10);
      await history.create(doc('d1', words: 10), now: base);
      await history.create(
        doc('d1', words: 20),
        now: base.add(const Duration(minutes: 5)),
      );
      final list = await history.list('d1');
      expect(list.length, 2);
      expect(list.first.words, 20);
      expect(list.last.words, 10);
      expect(list.first.createdAt.isAfter(list.last.createdAt), isTrue);
    });

    test('同毫秒重复创建不互相覆盖', () async {
      final at = DateTime(2026, 8, 1, 10);
      await history.create(doc('d1', words: 1), now: at);
      await history.create(doc('d1', words: 2), now: at);
      expect((await history.list('d1')).length, 2);
    });

    test('无快照文档返回空列表', () async {
      expect(await history.list('missing'), isEmpty);
    });

    test('损坏的单个快照文件不阻塞其它记录', () async {
      await history.create(doc('d1'), now: DateTime(2026, 8, 1));
      await File('${tmp.path}/d1/9999999999999.json').writeAsString('不是json');
      final list = await history.list('d1');
      expect(list.length, 1);
    });

    test('delete 移除快照文件', () async {
      final snapshot = await history.create(doc('d1'), now: DateTime(2026, 8, 1));
      await history.delete(snapshot);
      expect(await history.list('d1'), isEmpty);
    });
  });

  group('prune', () {
    test('超过 keep 上限时淘汰最旧的', () async {
      final small = SnapshotHistory(rootPath: tmp.path, keep: 3);
      final base = DateTime(2026, 8, 1, 8);
      for (var i = 0; i < 5; i++) {
        await small.create(
          doc('d1', words: i),
          now: base.add(Duration(minutes: i)),
        );
      }
      final list = await small.list('d1');
      expect(list.length, 3);
      // 留下的是最新的 3 份（words 2/3/4）。
      expect(list.map((s) => s.words).toList(), [4, 3, 2]);
    });
  });

  group('maybeAutoSnapshot', () {
    test('首次保存建基线快照', () async {
      final created = await history.maybeAutoSnapshot(
        doc('d1', words: 100),
        nextWords: 120,
        now: DateTime(2026, 8, 1, 10),
      );
      expect(created, isNotNull);
      expect((await history.list('d1')).length, 1);
    });

    test('空文档不留自动快照', () async {
      expect(
        await history.maybeAutoSnapshot(
          doc('d1', content: '{}', words: 0),
          nextWords: 10,
          now: DateTime(2026, 8, 1),
        ),
        isNull,
      );
      expect(
        await history.maybeAutoSnapshot(
          doc('d1', content: '', words: 0),
          nextWords: 10,
          now: DateTime(2026, 8, 1),
        ),
        isNull,
      );
    });

    test('间隔未到且无大删除时不留底', () async {
      final base = DateTime(2026, 8, 1, 10);
      await history.create(doc('d1', words: 100), now: base);
      final created = await history.maybeAutoSnapshot(
        doc('d1', words: 100),
        nextWords: 110,
        now: base.add(const Duration(minutes: 5)),
      );
      expect(created, isNull);
    });

    test('距上次快照超过间隔 → 周期留底', () async {
      final base = DateTime(2026, 8, 1, 10);
      await history.create(doc('d1', words: 100), now: base);
      final created = await history.maybeAutoSnapshot(
        doc('d1', words: 200),
        nextWords: 210,
        now: base.add(const Duration(minutes: 10)),
      );
      expect(created, isNotNull);
      expect((await history.list('d1')).length, 2);
    });

    test('单次保存大删除（绝对阈值）→ 留住删除前内容', () async {
      final base = DateTime(2026, 8, 1, 10);
      await history.create(doc('d1', words: 1000), now: base);
      final created = await history.maybeAutoSnapshot(
        doc('d1', words: 1000, content: '[{"insert":"删除前的完整内容"}]'),
        nextWords: 700, // 降 300 ≥ 200
        now: base.add(const Duration(minutes: 1)),
      );
      expect(created, isNotNull);
      expect(created!.content, '[{"insert":"删除前的完整内容"}]');
    });

    test('单次保存大删除（比例阈值）→ 小文档同样受保护', () async {
      final base = DateTime(2026, 8, 1, 10);
      await history.create(doc('d1', words: 300), now: base);
      final created = await history.maybeAutoSnapshot(
        doc('d1', words: 300),
        nextWords: 220, // 降 80：< 200 但 ≥ 50 且 ≥ 300×20%
        now: base.add(const Duration(minutes: 1)),
      );
      expect(created, isNotNull);
    });

    test('小幅删除不触发', () async {
      final base = DateTime(2026, 8, 1, 10);
      await history.create(doc('d1', words: 1000), now: base);
      final created = await history.maybeAutoSnapshot(
        doc('d1', words: 1000),
        nextWords: 960, // 降 40：不到任何阈值
        now: base.add(const Duration(minutes: 1)),
      );
      expect(created, isNull);
    });

    test('latestAt 跨实例从磁盘恢复（重启后仍能判定间隔）', () async {
      final base = DateTime(2026, 8, 1, 10);
      await history.create(doc('d1', words: 100), now: base);
      // 新实例（模拟重启）：缓存为空，需从目录扫描。
      final fresh = SnapshotHistory(rootPath: tmp.path);
      expect(await fresh.latestAt('d1'), base);
      final created = await fresh.maybeAutoSnapshot(
        doc('d1', words: 100),
        nextWords: 100,
        now: base.add(const Duration(minutes: 3)),
      );
      expect(created, isNull); // 间隔未到，基线已存在
    });

    test('快照文件内容完整可回读', () async {
      final at = DateTime(2026, 8, 1, 10);
      final snapshot = await history.create(
        doc('d1', title: '第一章', content: '[{"insert":"你好"}]', words: 2),
        now: at,
      );
      final raw =
          jsonDecode(await File(snapshot.path).readAsString())
              as Map<String, dynamic>;
      expect(raw['documentId'], 'd1');
      expect(raw['title'], '第一章');
      expect(raw['content'], '[{"insert":"你好"}]');
      expect(raw['words'], 2);
      expect(raw['createdAt'], at.millisecondsSinceEpoch);
    });
  });
}
