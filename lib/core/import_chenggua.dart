/// 橙瓜码字导入器：直接读取橙瓜码字本地 SQLite 库（`<uid>.db`），
/// 把「图书 → 卷 → 章节」结构映射为字在的「笔记本 → 分卷 → 章节」并批量入库。
///
/// 数据来源（已实测验证）：
/// - `book_category`：目录树。type 1=图书 / 2=卷 / 3=章节；`sorts`(JSON 数组)
///   决定子节点顺序（橙瓜偶发重复 uuid，导入时去重）；`is_deleted` 标记删除。
/// - `chapter_content`：章节正文为**纯文本**，段落以 `\t` 开头、段间空行分隔；
///   `volume_uuid` 指向所属卷；`created_at/updated_at` 为毫秒时间戳。
///
/// 导入语义：**追加合并**（不清空现有库）、不动 stats（外部导入不是今日新增）、
/// 分卷作为真卷写入（手动分卷模式）。源库仅只读打开，先复制到临时目录再解析。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite/sqflite.dart'
    show OpenDatabaseOptions, databaseFactory;

import '../util/platform.dart';
import 'db.dart' show Db, newId;
import 'export.dart' show emptyDeltaJson;
import 'models.dart' show Document, ImportResult, documentToSnapshotJson;
import 'word_count.dart' show wordCount;

/// 导入相关可读错误（UI 提示用）。
class ChengguaException implements Exception {
  const ChengguaException(this.message);

  final String message;

  @override
  String toString() => 'ChengguaException($message)';
}

/// 解析橙瓜库的结果：book_category（图书/卷/章节）+ chapter_content。
class _CategoryRow {
  _CategoryRow({
    required this.uuid,
    required this.parentUuid,
    required this.type,
    required this.title,
    required this.sorts,
    required this.createdAt,
    required this.updatedAt,
  });

  final String uuid;
  final String parentUuid;
  final int type; // 1 图书 / 2 卷 / 3 章节
  final String title;
  final String? sorts;
  final int createdAt;
  final int updatedAt;
}

class _ContentRow {
  _ContentRow({
    required this.chapterUuid,
    required this.volumeUuid,
    required this.bookUuid,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
  });

  final String chapterUuid;
  final String? volumeUuid;
  final String bookUuid;
  final String content;
  final int createdAt;
  final int updatedAt;
}

// 容错取值：SQLite 动态类型，GUID/NTEXT 列若存成整数/浮点（如空 parent/volume
// 存 0），强转会抛 TypeError。全部走 toString 兜底。
String _str(Object? v) => v == null ? '' : v.toString();
String? _strOrNull(Object? v) => v?.toString();
int _int(Object? v) => v is int ? v : (int.tryParse(v?.toString() ?? '') ?? 0);

/// 按 `sorts` 数组（去重）排序，缺项按 created_at 兜底。
List<String> _orderFromSorts(String? sortsJson, Map<String, int> createdAtBy) {
  final ordered = <String>[];
  if (sortsJson != null && sortsJson.isNotEmpty) {
    try {
      final arr = jsonDecode(sortsJson);
      if (arr is List) {
        for (final e in arr) {
          final id = e.toString();
          if (createdAtBy.containsKey(id) && !ordered.contains(id)) {
            ordered.add(id);
          }
        }
      }
    } on FormatException {
      // 非法 sorts 忽略，走 created_at 兜底
    }
  }
  final rest = createdAtBy.keys
      .where((id) => !ordered.contains(id))
      .toList()
    ..sort((a, b) {
      final c = createdAtBy[a]!.compareTo(createdAtBy[b]!);
      return c != 0 ? c : a.compareTo(b);
    });
  ordered.addAll(rest);
  return ordered;
}

/// 纯文本 → Delta JSON：每行一段（去段首 `\t`），行间 `\n`，末尾换行。
/// 空文本返回 `emptyDeltaJson`。
String plainTextToDelta(String text) {
  final lines = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.replaceFirst('\t', '').trimRight();
    if (line.trim().isNotEmpty) lines.add(line);
  }
  if (lines.isEmpty) return emptyDeltaJson;
  return jsonEncode([
    {'insert': '${lines.join('\n')}\n'},
  ]);
}

/// 读取并解析橙瓜库（只读），返回可直接交给 [Db.importExternal] 的条目。
///
/// 桌面端在独立 isolate 内运行（入口处自行初始化 ffi factory）；
/// Android 由调用方在主 isolate 内调用（native factory 已在 main 初始化）。
Future<Map<String, dynamic>> parseChengguaDb(String dbPath) async {
  if (isDesktopPlatform) {
    ffi.sqfliteFfiInit();
    databaseFactory = ffi.databaseFactoryFfi;
  }
  final db = await databaseFactory.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(readOnly: true),
  );
  try {
    final categoryRows = await db.query('book_category');
    final contentRows = await db.query('chapter_content');

    final categories = <_CategoryRow>[];
    for (final r in categoryRows) {
      if (_int(r['is_deleted']) != 0) continue; // 跳过已删除
      categories.add(
        _CategoryRow(
          uuid: _str(r['client_uuid']),
          parentUuid: _str(r['parent_client_uuid']),
          type: _int(r['type']),
          title: _str(r['title']),
          sorts: _strOrNull(r['sorts']),
          createdAt: _int(r['created_at']),
          updatedAt: _int(r['updated_at']),
        ),
      );
    }
    final contents = <String, _ContentRow>{
      for (final r in contentRows)
        if (_int(r['is_deleted']) == 0)
          _str(r['chapter_uuid']): _ContentRow(
            chapterUuid: _str(r['chapter_uuid']),
            volumeUuid: _strOrNull(r['volume_uuid']),
            bookUuid: _str(r['category_id']),
            content: _str(r['content']),
            createdAt: _int(r['created_at']),
            updatedAt: _int(r['updated_at']),
          ),
    };

    final books = categories.where((c) => c.type == 1).toList();
    final volumes = categories.where((c) => c.type == 2).toList();
    final chapters = categories.where((c) => c.type == 3).toList();

    final volumesByBook = <String, List<_CategoryRow>>{};
    final chaptersByVolume = <String?, List<_CategoryRow>>{};
    // 未归卷章节（挂在图书下 / content 无 volume_uuid）
    final looseChapters = <String, List<_CategoryRow>>{};

    for (final book in books) {
      // 候选集必须只含该父节点的直属子项，否则兜底排序会把别的卷/章节也加进来。
      final childCandidates = {
        for (final v in volumes.where((v) => v.parentUuid == book.uuid))
          v.uuid: v.createdAt,
        for (final ch in chapters.where((ch) => ch.parentUuid == book.uuid))
          ch.uuid: ch.createdAt,
      };
      final childOrder = _orderFromSorts(book.sorts, childCandidates);
      volumesByBook[book.uuid] = [
        for (final id in childOrder)
          if (volumes.any((v) => v.uuid == id))
            volumes.firstWhere((v) => v.uuid == id),
      ];
      final direct = [
        for (final id in childOrder)
          if (chapters.any((ch) => ch.uuid == id))
            chapters.firstWhere((ch) => ch.uuid == id),
      ];
      if (direct.isNotEmpty) looseChapters[book.uuid] = direct;
      // 卷内章节顺序
      for (final vol in volumesByBook[book.uuid]!) {
        final chapterCandidates = {
          for (final ch in chapters.where((ch) => ch.parentUuid == vol.uuid))
            ch.uuid: ch.createdAt,
        };
        chaptersByVolume[vol.uuid] = [
          for (final id in _orderFromSorts(vol.sorts, chapterCandidates))
            chapters.firstWhere((ch) => ch.uuid == id),
        ];
      }
    }
    // 卷不挂在任何书下（孤儿卷，数据异常）：跳过。

    // ── 生成新 id 并映射 ──
    final notebookIdOf = <String, String>{};
    final volumeIdOf = <String, String>{};
    final notebooks = <Map<String, dynamic>>[];
    final volsOut = <Map<String, dynamic>>[];
    final docsOut = <Map<String, dynamic>>[];

    for (var bi = 0; bi < books.length; bi++) {
      final book = books[bi];
      final nbId = newId('nb');
      notebookIdOf[book.uuid] = nbId;
      notebooks.add({
        'id': nbId,
        'name': book.title.isEmpty ? '导入笔记本' : book.title,
        'position': bi, // 相对位置；入库前由调用方加基准
        'createdAt': book.createdAt,
        'updatedAt': book.updatedAt,
      });

      final bookVolumes = volumesByBook[book.uuid] ?? const [];
      for (var vi = 0; vi < bookVolumes.length; vi++) {
        final vol = bookVolumes[vi];
        final volId = newId('vol');
        volumeIdOf[vol.uuid] = volId;
        volsOut.add({
          'id': volId,
          'notebookId': nbId,
          'name': vol.title.isEmpty ? '第${vi + 1}卷' : vol.title,
          'position': vi,
          'createdAt': vol.createdAt,
        });
      }

      var docIndex = 0;
      // 卷序优先（卷内章节按卷位置），最后收未归卷章节。
      final allChapters = <_CategoryRow>[];
      for (final vol in bookVolumes) {
        allChapters.addAll(chaptersByVolume[vol.uuid] ?? const []);
      }
      allChapters.addAll(looseChapters[book.uuid] ?? const []);
      for (final ch in allChapters) {
        final content = contents[ch.uuid];
        if (content == null) {
          // 无正文行的章节：空文档（保留标题）。
          docsOut.add(
            documentToSnapshotJson(
              Document(
                id: newId('doc'),
                notebookId: nbId,
                title: ch.title.isEmpty ? '未命名' : ch.title,
                content: emptyDeltaJson,
                words: 0,
                position: docIndex++,
                createdAt: ch.createdAt,
                updatedAt: ch.updatedAt,
              ),
            ),
          );
          continue;
        }
        final plain = content.content;
        final delta = plainTextToDelta(plain);
        final words = wordCount(
          plain
              .split('\n')
              .map((l) => l.replaceFirst('\t', '').trimRight())
              .where((l) => l.trim().isNotEmpty)
              .join('\n'),
        );
        final volumeId = content.volumeUuid != null
            ? volumeIdOf[content.volumeUuid!]
            : null;
        docsOut.add(
          documentToSnapshotJson(
            Document(
              id: newId('doc'),
              notebookId: nbId,
              title: ch.title.isEmpty ? '未命名' : ch.title,
              content: delta,
              words: words,
              position: docIndex++,
              volumeId: volumeId,
              createdAt: content.createdAt,
              updatedAt: content.updatedAt,
            ),
          ),
        );
      }
    }

    return {
      'notebooks': notebooks,
      'volumes': volsOut,
      'docs': docsOut,
    };
  } finally {
    await db.close();
  }
}

/// 探测橙瓜码字数据库文件（macOS/Windows 用户数据目录下的 `*.db`）。
///
/// 返回按最后修改时间倒序的文件列表；找不到返回空。macOS 的 `~/Library`
/// 在访达默认隐藏，手动找容易卡住——导入器直接自动探测，省去翻目录。
/// [rootOverride] 供测试注入目录。
Future<List<String>> detectChengguaDbFiles({String? rootOverride}) async {
  final roots = <String>[];
  if (rootOverride != null) {
    roots.add(rootOverride);
  } else if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      roots.add('$home/Library/Application Support/橙瓜码字');
    }
  } else if (Platform.isWindows) {
    final appdata = Platform.environment['APPDATA'];
    if (appdata != null && appdata.isNotEmpty) {
      roots.add('$appdata/橙瓜码字');
    }
  }
  final files = <File>[];
  for (final root in roots) {
    final dir = Directory(root);
    if (!await dir.exists()) continue;
    await for (final e in dir.list()) {
      if (e is File &&
          e.path.endsWith('.db') &&
          !e.path.endsWith('-wal') &&
          !e.path.endsWith('-shm')) {
        files.add(e);
      }
    }
  }
  files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return files.map((f) => f.path).toList();
}

/// 导入橙瓜码字库：复制源库 → 解析（桌面 isolate）→ 编排 position → 批量入库。
///
/// 返回导入统计；[tempDir] 供测试注入（非空则不清理）。
Future<ImportResult> importChenggua(
  Db target,
  String sourceDbPath, {
  Directory? tempDir,
}) async {
  if (!await File(sourceDbPath).exists()) {
    throw const ChengguaException('找不到橙瓜码字数据库文件');
  }
  final tmp =
      tempDir ?? await Directory.systemTemp.createTemp('zizai_chenggua');
  await tmp.create(recursive: true);
  final copyPath = '${tmp.path}${Platform.pathSeparator}chenggua.db';
  await File(sourceDbPath).copy(copyPath);

  final Map<String, dynamic> parsed;
  try {
    if (isDesktopPlatform) {
      parsed = await Isolate.run(() => parseChengguaDb(copyPath));
    } else {
      parsed = await parseChengguaDb(copyPath);
    }
  } catch (e) {
    if (tempDir == null) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
    if (e is ChengguaException) rethrow;
    throw ChengguaException('解析橙瓜数据库失败: $e');
  }

  // 笔记本 position 追加在现有库末尾（避免与既有笔记本的 position 冲突）。
  final existing = await target.listNotebooks();
  final base =
      existing.isEmpty ? 0 : (existing.last.position + 1).clamp(0, 1 << 30);
  final notebooks = <Map<String, dynamic>>[];
  for (var i = 0; i < (parsed['notebooks'] as List).length; i++) {
    final n = ((parsed['notebooks'] as List)[i] as Map).cast<String, dynamic>();
    n['position'] = base + i;
    notebooks.add(n);
  }

  try {
    return await target.importExternal(
      notebooks: notebooks,
      volumes: (parsed['volumes'] as List).cast<Map<String, dynamic>>(),
      docs: (parsed['docs'] as List).cast<Map<String, dynamic>>(),
    );
  } finally {
    if (tempDir == null) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
}
