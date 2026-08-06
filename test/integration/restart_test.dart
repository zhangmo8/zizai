import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/export.dart' show deltaToPlainText;
import 'package:zi_zai/core/models.dart';
import 'package:zi_zai/state/library_controller.dart';
import 'package:zi_zai/state/settings_controller.dart';

/// 真实调用链（非 mock）：写→存→重启→恢复；切换先保存；设置持久化。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_restart');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  String dbPath() => '${tempDir.path}/zi-zai.db';

  test('写→存→重启→恢复：内容仍在，今日增量正确', () async {
    // 第一次会话：建库、写 300 字
    final db1 = await Db.open(dbPath());
    final nb = await db1.createNotebook('小说');
    final doc = await db1.createDocument(nb.id, title: '第一章');
    final content = '字' * 300;
    await db1.saveDocument(id: doc.id, title: doc.title, content: '[{"insert":"$content"}]');
    await db1.saveLastOpen(notebookId: nb.id, documentId: doc.id, words: 300);
    await db1.close();

    // 重启：全新会话（新连接、重走打开/迁移/恢复流程）
    final db2 = await Db.open(dbPath());
    final settings = SettingsController(db2);
    await settings.load();
    final library = LibraryController(db2);
    await library.restore();

    expect(library.currentDocument?.id, doc.id); // last_open 恢复
    expect(library.todayDelta, 300); // 今日增量
    final loaded = await db2.getDocument(doc.id);
    expect(deltaToPlainText(loaded!.content), '字' * 300);
    expect(loaded.words, 300);
    await db2.close();
  });

  test('侧边栏切换文档：旧文档先保存（beforeSwitchSave 真实链路）', () async {
    final db = await Db.open(dbPath());
    final nb = await db.createNotebook('小说');
    final d1 = await db.createDocument(nb.id, title: '第一章');
    final d2 = await db.createDocument(nb.id, title: '第二章');
    await db.saveLastOpen(notebookId: nb.id, documentId: d1.id, words: 0);

    final settings = SettingsController(db);
    await settings.load();
    final library = LibraryController(db);
    await library.restore();

    // 编辑器挂接：切换前保存（与 EditorView.initState 相同接线）
    var savedContent = '';
    library.beforeSwitchSave = () async {
      await library.saveCurrentDocument(title: d1.title, content: '[{"insert":"切换前写入"}]');
      savedContent = (await db.getDocument(d1.id))!.content;
    };
    await library.switchDocument(d2.id);

    expect(library.currentDocument?.id, d2.id);
    expect(deltaToPlainText(savedContent), '切换前写入');
    final persisted = await db.getDocument(d1.id);
    expect(deltaToPlainText(persisted!.content), '切换前写入');
    await db.close();
  });

  test('设置持久化：改主题/目标字数后重启仍生效', () async {
    final db1 = await Db.open(dbPath());
    final settings1 = SettingsController(db1);
    await settings1.load();
    await settings1.update(const Settings(theme: 'dark', dailyGoal: 5000));
    await db1.close();

    final db2 = await Db.open(dbPath());
    final settings2 = SettingsController(db2);
    await settings2.load();
    expect(settings2.settings.theme, 'dark');
    expect(settings2.settings.dailyGoal, 5000);
    expect(settings2.themeMode, ThemeMode.dark);
    await db2.close();
  });
}
