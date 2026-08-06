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
const int currentSchemaVersion = 1;

/// 单级迁移：`to` 为目标版本，`up` 执行该级全部 DDL/DML。
class SchemaMigration {
  const SchemaMigration({required this.to, required this.up});

  final int to;
  final Future<void> Function(DatabaseExecutor db) up;
}

/// 迁移链：v1 为初始 schema（onCreate 直接建立），后续版本按序追加。
/// 纪律：任何 schema 变更 = 同一任务内完成「迁移脚本 + 回放测试」。
final List<SchemaMigration> schemaMigrations = <SchemaMigration>[];

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
          onCreate: (db, _) => _createSchemaV1(db),
          onUpgrade: (db, oldV, newV) async {
            await backupDbFile(path);
            await runMigrations(db, oldV, newV, migrations ?? schemaMigrations);
          },
        ),
      );
      return Db._(db, path, clock);
    } on LibraryException {
      rethrow;
    } catch (e) {
      throw LibraryException('打开数据库失败: $e', path: path);
    }
  }

  final Database _db;
  final String _path;
  final DateTime Function()? _clock;

  int _nowMs() => (_clock?.call() ?? DateTime.now()).millisecondsSinceEpoch;

  /// 库文件路径（内存库为 `inMemoryDatabasePath`），设置页展示用。
  String get path => _path;

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
    await _db.insert('notebooks', {
      'id': id,
      'name': name,
      'position': position,
      'created_at': now,
    });
    return Notebook(id: id, name: name, position: position, createdAt: now);
  }

  Future<List<Notebook>> listNotebooks() async {
    final rows = await _db.query('notebooks', orderBy: 'position ASC, created_at ASC');
    return rows.map(Notebook.fromRow).toList();
  }

  Future<void> renameNotebook(String id, String name) async {
    final n = await _db.update('notebooks', {'name': name}, where: 'id = ?', whereArgs: [id]);
    if (n == 0) throw LibraryException('笔记本不存在: $id', path: _path);
  }

  Future<void> deleteNotebook(String id) async {
    final n = await _db.delete('notebooks', where: 'id = ?', whereArgs: [id]);
    if (n == 0) throw LibraryException('笔记本不存在: $id', path: _path);
  }

  Future<void> moveNotebook(String id, {required bool up}) =>
      _swapPosition('notebooks', id, up);

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
  }

  Future<void> deleteDocument(String id) async {
    final n = await _db.delete('documents', where: 'id = ?', whereArgs: [id]);
    if (n == 0) throw LibraryException('文档不存在: $id', path: _path);
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
    return _db.transaction((txn) async {
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
      if (delta != 0) {
        await _applyDeltaToStats(txn, _todayKey(now), delta);
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
  }

  // ── 设置 ──────────────────────────────────────────────────

  Future<String?> getSetting(String key) async {
    final rows = await _db.query('settings', columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value']! as String;
  }

  Future<void> setSetting(String key, String value) async {
    await _db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Settings> loadSettings() async {
    final rows = await _db.query('settings');
    final kv = <String, String>{
      for (final r in rows) r['key']! as String: r['value']! as String,
    };
    return Settings.fromMap(kv);
  }

  Future<void> saveSettings(Settings s) async {
    for (final entry in s.toMap().entries) {
      await setSetting(entry.key, entry.value);
    }
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

  Future<void> _swapPosition(
    String table,
    String id,
    bool up,
  ) async {
    await _db.transaction(
      (txn) => _swapPositionIn(txn, table, id, up),
    );
  }

  /// 在排序列表内与相邻项交换 position；已到边界则 no-op。
  Future<void> _swapPositionIn(
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
    if (target < 0 || target >= rows.length) return;
    final cur = rows[idx]['position']! as int;
    final other = rows[target]['position']! as int;
    await txn.update(table, {'position': other}, where: 'id = ?', whereArgs: [id]);
    await txn.update(table, {'position': cur}, where: 'id = ?', whereArgs: [rows[target]['id']]);
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
}
