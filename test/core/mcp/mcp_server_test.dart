import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zi_zai/core/db.dart';
import 'package:zi_zai/core/mcp/mcp_server.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('服务启动后 agent 可连接、列工具、读/写章节', () async {
    final db = await Db.open(inMemoryDatabasePath);
    final nb = await db.createNotebook('小说');
    final doc = await db.createDocument(
      nb.id,
      title: '第一章',
      content: '[{"insert":"正文内容"}]',
    );

    // 端口 0 = 系统分配，避免 CI 端口冲突。
    final server = ZizaiMcpServer(db: db, port: 0);
    await server.start();
    expect(server.isRunning, isTrue);
    expect(server.boundPort, greaterThan(0));
    expect(server.url, 'http://127.0.0.1:${server.boundPort}/mcp');

    final client = McpClient(
      const Implementation(name: 'zizai-mcp-test', version: '1.0.0'),
      options: const McpClientOptions(protocol: McpProtocol.stable),
    );
    final transport = StreamableHttpClientTransport(Uri.parse(server.url));
    await client.connect(transport);
    try {
      final toolsResult = await client.listTools();
      final names = [for (final t in toolsResult.tools) t.name];
      expect(
        names,
        containsAll([
          'list_notebooks',
          'list_documents',
          'read_document',
          'search_documents',
          'create_document',
          'append_document',
        ]),
      );

      final read = await client.callTool(
        CallToolRequest(
          name: 'read_document',
          arguments: {'documentId': doc.id},
        ),
      );
      expect(read.isError, isFalse);
      expect((read.content.first as TextContent).text, contains('正文内容'));

      final append = await client.callTool(
        CallToolRequest(
          name: 'append_document',
          arguments: {'documentId': doc.id, 'content': '续写段落'},
        ),
      );
      expect(append.isError, isFalse);
      final updated = await db.getDocument(doc.id);
      expect(updated!.content, contains('续写段落'));
    } finally {
      await transport.close();
      await server.stop();
      await db.close();
    }
  });

  test('stop 后服务不可达', () async {
    final db = await Db.open(inMemoryDatabasePath);
    final server = ZizaiMcpServer(db: db, port: 0);
    await server.start();
    final url = server.url;
    await server.stop();
    expect(server.isRunning, isFalse);
    final client = McpClient(
      const Implementation(name: 'zizai-mcp-test', version: '1.0.0'),
    );
    await expectLater(
      client.connect(StreamableHttpClientTransport(Uri.parse(url))),
      throwsA(anything),
    );
    await db.close();
  });
}
