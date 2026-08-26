import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/state/mcp_controller.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('默认关闭；开启后运行并提供地址；关闭后停止；配置持久化', () async {
    final db = await Db.open(inMemoryDatabasePath);
    final mcp = McpController(db, initialPort: 0);
    await mcp.init();
    expect(mcp.enabled, isFalse);
    expect(mcp.running, isFalse);
    expect(mcp.url, isNull);

    await mcp.setEnabled(true);
    expect(mcp.enabled, isTrue);
    expect(mcp.running, isTrue);
    expect(mcp.url, startsWith('http://127.0.0.1:'));
    expect(await db.getSetting(McpController.kEnabledKey), 'true');

    await mcp.setEnabled(false);
    expect(mcp.running, isFalse);
    expect(await db.getSetting(McpController.kEnabledKey), 'false');

    mcp.dispose();
    await db.close();
  });

  test('enabled 持久化后，新控制器 init 自动恢复服务', () async {
    final db = await Db.open(inMemoryDatabasePath);
    final first = McpController(db, initialPort: 0);
    await first.init();
    await first.setEnabled(true);
    first.dispose();

    final second = McpController(db, initialPort: 0);
    await second.init();
    expect(second.enabled, isTrue);
    expect(second.running, isTrue);
    expect(second.url, isNotNull);

    await second.setEnabled(false);
    second.dispose();
    await db.close();
  });

  test('setPort 自动端口（0）→ 实际端口可用；重启后生效', () async {
    final db = await Db.open(inMemoryDatabasePath);
    final mcp = McpController(db, initialPort: 0);
    await mcp.init();
    await mcp.setEnabled(true);
    await mcp.setPort(0); // 运行中改端口 → 重启绑定新空闲端口
    expect(mcp.running, isTrue);
    expect(mcp.port, greaterThan(0));
    expect(mcp.url, startsWith('http://127.0.0.1:'));
    expect(await db.getSetting(McpController.kPortKey), '0');

    await mcp.setEnabled(false);
    mcp.dispose();
    await db.close();
  });
}
