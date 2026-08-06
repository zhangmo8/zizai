/// SQLite 数据层：schema v1 + 迁移链框架 + 全部 CRUD。
///
/// 设计依据：docs/app/README.md §4（数据模型/增量规则）、docs/app/update.md §2
/// （DB 版本与迁移：升级前备份、失败停止启动、只前向不回退）。
library;

import 'dart:io';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'export.dart' show deltaToPlainText, emptyDeltaJson;
import 'models.dart';
import 'word_count.dart';

/// 当前代码里的 DB schema 版本（`PRAGMA user_version`）。
/// v1：基础五表；v2：+ sync_journal（云同步脏标记）。
const int currentSchemaVersion = 2;

/// 单级迁移：`to` 为目标版本，`up` 执行该级全部 DDL/DML。
class SchemaMigration {
  const SchemaMigration({required this.to, required this.up});

  final int to;
  final Future<void> Function(DatabaseExecutor db) up;
}

/// 迁移链：v1 为初始 schema（onCreate 直接建立），后续版本按序追加。
/// 纪律：任何 schema 变更 = 同一任务内完成「迁移脚本 + 回放测试」。
final List<SchemaMigration> schemaMigrations = <SchemaMigration>[
  // v2：云同步脏标记表 + notebooks.updated_at（LWW 时间基准，sync-engine-002）。
  // 实体 id 通用列（docs/notebooks/settings/stats）。
  SchemaMigration(
    to: 2,
    up: (db) async {
      await db.execute('''
CREATE TABLE sync_journal (
  entity_id      TEXT PRIMARY KEY,
  dirty          INTEGER NOT NULL DEFAULT 1,
  last_pushed_at INTEGER,
  last_pulled_at INTEGER
)''');
      await db.execute(
          'ALTER TABLE notebooks ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0');
    },
  ),
];

/// 逐级执行 `from+1 .. to` 的迁移；缺某级脚本抛 [StateError]。
Future<void> runMigrations(
  DatabaseExecutor db,
  int from,
  int to,
  List<SchemaMigration> chain,
) async {
  for (var v = from + 1; v <= to; v++) {
    SchemaMigration? hit;
    for (final m in chain) {
      if (m.to == v) {
        hit = m;
        break;
      }
    }
    if (hit == null) {
      throw StateError('缺少迁移到 schema v$v 的脚本');
    }
    await hit.up(db);
  }
}

/// 升级前备份：`dbPath` → `dbPath.bak`，滚动保留最近 3 份
/// （`.bak` / `.bak.1` / `.bak.2`）。内存库跳过。
Future<void> backupDbFile(String dbPath) async {
  if (dbPath.isEmpty || dbPath == inMemoryDatabasePath) return;
  final file = File(dbPath);
  if (!await file.exists()) return;
  final bak2 = File('$dbPath.bak.2');
  final bak1 = File('$dbPath.bak.1');
  final bak = File('$dbPath.bak');
  if (await bak2.exists()) await bak2.delete();
  if (await bak1.exists()) await bak1.rename('$dbPath.bak.2');
  if (await bak.exists()) await bak.rename('$dbPath.bak.1');
  await file.copy('$dbPath.bak');
}

final Random _rng = Random.secure();

String _newId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '-${_rng.nextInt(0xffffff).toRadixString(36)}';

String _todayKey(int nowMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final mm = dt.month.toString().padLeft(2, '0');
  final dd = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$mm-$dd';
}

class Db {
  Db._(this._db, this._path, [this._clock]);

  /// 打开库。`path` 为 db 文件路径或 `inMemoryDatabasePath`。
  ///
  /// - 版本低于 [version] → 先备份再逐级迁移；迁移失败抛 [LibraryException]（调用方停止启动提示）。
  /// - 打开失败抛可恢复 [LibraryException]，不吞异常。
  static Future<Db> open(
    String path, {
    int version = currentSchemaVersion,
    List<SchemaMigration>? migrations,
    DateTime Function()? clock,
  }) async {
    try {
      final db = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: version,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
          onCreate: (db, version) async {
            // fresh 库：建 v1 后逐级迁移到当前版本（与升级路径同链）。
            await _createSchemaV1(db);
            await runMigrations(db, 1, version, migrations ?? schemaMigrations);
          },
          onUpgrade: (db, oldV, newV) async {
            await backupDbFile(path);
            await runMigrations(db, oldV, newV, migrations ?? schemaMigrations);
          },
        ),
      );
      final instance = Db._(db, path, clock);
      await instance._initCapabilities();
      return instance;
    } on LibraryException {
      rethrow;
    } catch (e) {
      throw LibraryException('打开数据库失败: $e', path: path);
    }
  }
  final Database _db;
  final String _path;
  final DateTime Function()? _clock;

  /// 本地数据变更回调（云同步引擎挂接：保存/增删改后触发推送调度）。
  /// 引擎在 pull 应用期间自行抑制（置 null 再恢复），避免推送回环。
  void Function()? onMutation;

  int _nowMs() => (_clock?.call() ?? DateTime.now()).millisecondsSinceEpoch;

  /// sync_journal / notebooks.updated_at 是否存在（v1 库/迁移测试中写入时容忍缺列）。
  /// open 时一次性探测并缓存，避免每次写操作的往返开销。
  bool? _syncJournalExists;
  bool? _nbHasUpdatedAt;

  Future<void> _initCapabilities() async {
    final j = await _db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_journal' LIMIT 1");
    _syncJournalExists = j.isNotEmpty;
    final cols = await _db.rawQuery('PRAGMA table_info(notebooks)');
    _nbHasUpdatedAt = cols.any((r) => r['name'] == 'updated_at');
  }

  bool get _notebooksHaveUpdatedAt => _nbHasUpdatedAt ?? false;

  Future<void> _markDirty(String entityId) async {
    if (_syncJournalExists == false) return;
    await _db.insert(
      'sync_journal',
      {'entity_id': entityId, 'dirty': 1},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    onMutation?.call();
  }

  /// 事务内标记脏（saveDocument 在事务中，不能用 _db 再开事务）。
  Future<void> _markDirtyOn(DatabaseExecutor txn, String entityId) async {
    if (_syncJournalExists == false) return;
    await txn.insert(
      'sync_journal',
      {'entity_id': entityId, 'dirty': 1},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 库文件路径（内存库为 `inMemoryDatabasePath`），设置页展示用。
  String get path => _path;

  /// 当前 DB schema 版本（`PRAGMA user_version`，设置页「关于」区展示）。
  Future<int> schemaVersion() async {
    final rows = await _db.rawQuery('PRAGMA user_version');
    return (rows.first['user_version']! as int?) ?? 0;
  }

  Future<void> close() => _db.close();

  static Future<void> _createSchemaV1(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE notebooks (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  position   INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)''');
    await db.execute('''
CREATE TABLE documents (
  id          TEXT PRIMARY KEY,
  notebook_id TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
  title       TEXT NOT NULL,
  content     TEXT NOT NULL DEFAULT '{}',
  words       INTEGER NOT NULL DEFAULT 0,
  position    INTEGER NOT NULL DEFAULT 0,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
)''');
    await db.execute('''
CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
)''');
    await db.execute('''
CREATE TABLE stats (
  date  TEXT PRIMARY KEY,
  words INTEGER NOT NULL
)''');
    await db.execute('''
CREATE TABLE last_open (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  notebook_id TEXT,
  document_id TEXT,
  words       INTEGER NOT NULL DEFAULT 0
)''');
  }

  // ── 笔记本 ────────────────────────────────────────────────

  Future<Notebook> createNotebook(String name) async {
    final id = _newId('nb');
    final now = _nowMs();
    final position = await _count('notebooks');
    final hasUpdatedAt = _notebooksHaveUpdatedAt;
    await _db.insert('notebooks', {
      'id': id,
      'name': name,
      'position': position,
      'created_at': now,
      if (hasUpdatedAt) 'updated_at': now,
    });
    await _markDirty(id);
    return Notebook(
        id: id, name: name, position: position, createdAt: now, updatedAt: now);
  }

  Future<List<Notebook>> listNotebooks() async {
    final rows = await _db.query('notebooks', orderBy: 'position ASC, created_at ASC');
    return rows.map(Notebook.fromRow).toList();
  }

  Future<Notebook?> getNotebook(String id) async {
    final rows = await _db.query('notebooks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Notebook.fromRow(rows.first);
  }

  Future<void> renameNotebook(String id, String name) async {
    final now = _nowMs();
    final hasUpdatedAt = _notebooksHaveUpdatedAt;
    final n = await _db.update('notebooks', {
      'name': name,
      if (hasUpdatedAt) 'updated_at': now,
    }, where: 'id = ?', whereArgs: [id]);
    if (n == 0) throw LibraryException('笔记本不存在: $id', path: _path);
    await _markDirty(id);
  }

  Future<void> deleteNotebook(String id) async {
    // 级联删除的文档也要推送 tombstone，先逐个标记脏。
    final docs = await _db.query('documents', columns: ['id'], where: 'notebook_id = ?', whereArgs: [id]);
    final n = await _db.delete('notebooks', where: 'id = ?', whereArgs: [id]);
    if (n == 0) throw LibraryException('笔记本不存在: $id', path: _path);
    for (final row in docs) {
      await _markDirty(row['id']! as String);
    }
    await _markDirty(id);
  }

  Future<void> moveNotebook(String id, {required bool up}) async {
    final now = _nowMs();
    final hasUpdatedAt = _notebooksHaveUpdatedAt;
    final otherId = await _swapPosition('notebooks', id, up);
    // 位置属于同步数据（notebook envelope），两个行都要推送。
    if (hasUpdatedAt) {
      await _db.update('notebooks', {'updated_at': now}, where: 'id = ?', whereArgs: [id]);
      if (otherId != null) {
        await _db.update('notebooks', {'updated_at': now}, where: 'id = ?', whereArgs: [otherId]);
      }
    }
    if (otherId != null) {
      await _markDirty(otherId);
    }
    await _markDirty(id);
  }

  // ── 文档 ──────────────────────────────────────────────────

  Future<Document> createDocument(
    String notebookId, {
    String title = '未命名',
    String content = emptyDeltaJson,
  }) async {
    final id = _newId('doc');
    final now = _nowMs();
    final position = await _count(
      'documents',
      where: 'notebook_id = ?',
      whereArgs: [notebookId],
    );
    final words = _wordsOf(content);
    await _db.insert('documents', {
      'id': id,
      'notebook_id': notebookId,
      'title': title,
      'content': content,
      'words': words,
      'position': position,
      'created_at': now,
      'updated_at': now,
    });
    await _markDirty(id);
    return Document(
      id: id,
      notebookId: notebookId,
      title: title,
      content: content,
      words: words,
      position: position,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<List<Document>> listDocuments(String notebookId) async {
    final rows = await _db.query(
      'documents',
      where: 'notebook_id = ?',
      whereArgs: [notebookId],
      orderBy: 'position ASC, created_at ASC',
    );
    return rows.map(Document.fromRow).toList();
  }

  Future<Document?> getDocument(String id) async {
    final rows = await _db.query('documents', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Document.fromRow(rows.first);
  }

  Future<void> renameDocument(String id, String title) async {
    final now = _nowMs();
    final n = await _db.update(
      'documents',
      {'title': title, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (n == 0) throw LibraryException('文档不存在: $id', path: _path);
    await _markDirty(id);
  }

  Future<void> deleteDocument(String id) async {
    final n = await _db.delete('documents', where: 'id = ?', whereArgs: [id]);
    if (n == 0) throw LibraryException('文档不存在: $id', path: _path);
    await _markDirty(id);
  }

  Future<void> moveDocument(String id, {required bool up}) async {
    await _db.transaction((txn) async {
      final rows = await txn.query('documents', where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) throw LibraryException('文档不存在: $id', path: _path);
      final notebookId = rows.first['notebook_id']! as String;
      await _swapPositionIn(
        txn,
        'documents',
        id,
        up,
        where: 'notebook_id = ?',
        whereArgs: [notebookId],
      );
    });
  }

  /// 保存文档：更新内容/标题，重算字数快照，返回本次字数增量；
  /// 增量非零时累加当日 stats（负数不下探到 0），并同步 last_open 快照。
  ///
  /// 增量规则见 docs/app/README.md §4。
  Future<int> saveDocument({
    required String id,
    required String title,
    required String content,
  }) async {
    final now = _nowMs();
    final delta = await _db.transaction((txn) async {
      final rows = await txn.query('documents', where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) throw LibraryException('保存失败: 文档不存在 $id', path: _path);
      final oldWords = rows.first['words']! as int;
      final newWords = _wordsOf(content);
      final delta = newWords - oldWords;
      await txn.update(
        'documents',
        {'title': title, 'content': content, 'words': newWords, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      await _markDirtyOn(txn, id);
      if (delta != 0) {
        await _applyDeltaToStats(txn, _todayKey(now), delta);
        await _markDirtyOn(txn, 'stats');
      }
      await txn.insert(
        'last_open',
        {
          'id': 1,
          'notebook_id': rows.first['notebook_id']! as String,
          'document_id': id,
          'words': newWords,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return delta;
    });
    // 事务内 _markDirtyOn 不触发回调；提交后通知（同步引擎 30s 防抖推送）。
    onMutation?.call();
    return delta;
  }

  // ── 设置 ──────────────────────────────────────────────────

  Future<String?> getSetting(String key) async {
    final rows = await _db.query('settings', columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value']! as String;
  }

  Future<void> setSetting(String key, String value, {bool syncDirty = true}) async {
    await _db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
    // sync.* 键是设备本地配置（token/enabled/deviceId/拉取游标），不参与同步推送。
    if (syncDirty && !key.startsWith('sync.')) {
      await _markDirty('settings');
    }
  }

  Future<Settings> loadSettings() async {
    final rows = await _db.query('settings');
    final kv = <String, String>{
      for (final r in rows) r['key']! as String: r['value']! as String,
    };
    return Settings.fromMap(kv);
  }

  Future<void> saveSettings(Settings s) async {
    // 批量写入 + 单次脏标记（避免逐键往返与重复触发推送）。
    for (final entry in s.toMap().entries) {
      await _db.insert('settings', {'key': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await _markDirty('settings');
  }

  // ── 今日增量 ──────────────────────────────────────────────

  /// 当日累计增量（无记录返回 0）。
  Future<int> todayDelta({int? nowMs}) async {
    final key = _todayKey(nowMs ?? _nowMs());
    final rows = await _db.query('stats', columns: ['words'], where: 'date = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? 0 : rows.first['words']! as int;
  }

  // ── last_open ─────────────────────────────────────────────

  Future<LastOpen?> loadLastOpen() async {
    final rows = await _db.query('last_open', where: 'id = 1', limit: 1);
    return rows.isEmpty ? null : LastOpen.fromRow(rows.first);
  }

  Future<void> saveLastOpen({String? notebookId, String? documentId, int words = 0}) async {
    await _db.insert(
      'last_open',
      {'id': 1, 'notebook_id': notebookId, 'document_id': documentId, 'words': words},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ── 内部工具 ──────────────────────────────────────────────

  Future<int> _count(String table, {String? where, List<Object?>? whereArgs}) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $table${where == null ? '' : ' WHERE $where'}',
      whereArgs,
    );
    return rows.first['c']! as int;
  }

  int _wordsOf(String deltaJson) {
    try {
      return wordCount(deltaToPlainText(deltaJson));
    } on FormatException catch (e) {
      throw LibraryException('内容不是有效 Delta: ${e.message}', path: _path);
    }
  }

  Future<String?> _swapPosition(
    String table,
    String id,
    bool up,
  ) async {
    String? otherId;
    await _db.transaction((txn) async {
      otherId = await _swapPositionIn(txn, table, id, up);
    });
    return otherId;
  }

  /// 在排序列表内与相邻项交换 position；已到边界则 no-op。返回被换位的对方 id。
  Future<String?> _swapPositionIn(
    DatabaseExecutor txn,
    String table,
    String id,
    bool up, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final rows = await txn.query(
      table,
      columns: ['id', 'position'],
      where: where,
      whereArgs: whereArgs,
      orderBy: 'position ASC, created_at ASC',
    );
    final idx = rows.indexWhere((r) => r['id'] == id);
    if (idx < 0) throw LibraryException('记录不存在: $id', path: _path);
    final target = up ? idx - 1 : idx + 1;
    if (target < 0 || target >= rows.length) return null;
    final cur = rows[idx]['position']! as int;
    final other = rows[target]['position']! as int;
    await txn.update(table, {'position': other}, where: 'id = ?', whereArgs: [id]);
    await txn.update(table, {'position': cur}, where: 'id = ?', whereArgs: [rows[target]['id']]);
    return rows[target]['id'] as String;
  }

  /// 当日 stats 增减：delta 为负时扣减但不下探到 0 以下。
  Future<void> _applyDeltaToStats(DatabaseExecutor txn, String dateKey, int delta) async {
    final rows = await txn.query('stats', columns: ['words'], where: 'date = ?', whereArgs: [dateKey], limit: 1);
    final current = rows.isEmpty ? 0 : rows.first['words']! as int;
    final next = current + delta < 0 ? 0 : current + delta;
    if (rows.isEmpty) {
      if (next > 0) {
        await txn.insert('stats', {'date': dateKey, 'words': next});
      }
    } else {
      await txn.update('stats', {'words': next}, where: 'date = ?', whereArgs: [dateKey]);
    }
  }

  // ── 云同步支持（sync-engine-002）───────────────────────────

  /// 脏实体 id 列表（待推送）。
  Future<List<String>> dirtyEntityIds() async {
    final rows = await _db.query('sync_journal',
        columns: ['entity_id'], where: 'dirty = 1');
    return rows.map((r) => r['entity_id']! as String).toList();
  }

  /// 推送成功后清除脏标记并记录推送时间。
  Future<void> clearDirty(String entityId, {required int serverTime}) async {
    await _db.update(
      'sync_journal',
      {'dirty': 0, 'last_pushed_at': serverTime},
      where: 'entity_id = ?',
      whereArgs: [entityId],
    );
  }

  /// 云端应用（pull）后记录该实体的拉取时间。
  Future<void> touchPulled(String entityId, {required int serverTime}) async {
    await _db.insert(
      'sync_journal',
      {'entity_id': entityId, 'dirty': 0, 'last_pulled_at': serverTime},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 全部设置 KV（同步推送用；token 等 sync.* 键由引擎剔除）。
  Future<Map<String, String>> allSettings() async {
    final rows = await _db.query('settings');
    return {
      for (final r in rows) r['key']! as String: r['value']! as String,
    };
  }

  /// 全部 stats（date → words）。
  Future<Map<String, int>> allStats() async {
    final rows = await _db.query('stats');
    return {
      for (final r in rows) r['date']! as String: r['words']! as int,
    };
  }

  /// 云端 stats 应用：按 date 键合并（取较大值，保守不丢字）。
  Future<void> upsertStat(String date, int words) async {
    final rows = await _db.query('stats', columns: ['words'], where: 'date = ?', whereArgs: [date], limit: 1);
    final current = rows.isEmpty ? 0 : rows.first['words']! as int;
    final next = words > current ? words : current;
    if (rows.isEmpty) {
      if (next > 0) {
        await _db.insert('stats', {'date': date, 'words': next});
      }
    } else if (next != current) {
      await _db.update('stats', {'words': next}, where: 'date = ?', whereArgs: [date]);
    }
  }

  /// 云端文档应用（LWW 胜者）：更新或新建，不标记脏、不重算增量。
  Future<void> applyCloudDocument({
    required String id,
    required String notebookId,
    required String title,
    required String content,
    required int words,
    required int updatedAt,
  }) async {
    final now = _nowMs();
    final n = await _db.update(
      'documents',
      {'title': title, 'content': content, 'words': words, 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (n == 0) {
      await _db.insert('documents', {
        'id': id,
        'notebook_id': notebookId,
        'title': title,
        'content': content,
        'words': words,
        'position': 0,
        'created_at': now,
        'updated_at': updatedAt,
      });
    }
  }

  /// 云端笔记本应用（LWW 胜者）：更新或新建，不标记脏。
  Future<void> applyCloudNotebook({
    required String id,
    required String name,
    required int position,
    required int updatedAt,
  }) async {
    final now = _nowMs();
    final n = await _db.update(
      'notebooks',
      {'name': name, 'position': position, 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (n == 0) {
      await _db.insert('notebooks', {
        'id': id,
        'name': name,
        'position': position,
        'created_at': now,
        'updated_at': updatedAt,
      });
    }
  }

  /// 云端 tombstone 应用：物理删除本地行（不标记脏，避免回推）。
  Future<void> removeEntityNoDirty(String table, String id) async {
    await _db.delete(table, where: 'id = ?', whereArgs: [id]);
  }
}
