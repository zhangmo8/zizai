/// 本地 MCP 服务：mcp_dart 的 Streamable HTTP 服务端，仅绑 127.0.0.1。
///
/// 生命周期由 lib/state/mcp_controller.dart 管理（设置开关 → start/stop）。
/// 设计：docs/app/ui-settings.md「AI 协作（本地 MCP）」。
library;

import 'package:mcp_dart/mcp_dart.dart';

import '../db.dart';
import '../snapshot_history.dart';
import 'mcp_tools.dart';

/// 字在本地 MCP 服务（Streamable HTTP，路径 /mcp）。
class ZizaiMcpServer {
  ZizaiMcpServer({
    required this.db,
    this.snapshots,
    this.onWrite,
    this.port = 8765,
  });

  final Db db;
  final SnapshotHistory? snapshots;

  /// 写操作成功后回调（刷新 UI 目录树，见 mcp_tools.dart）。
  final Future<void> Function()? onWrite;

  /// 监听端口（可在设置里改；start 后以 [boundPort] 为准）。
  int port;

  StreamableMcpServer? _streamable;

  bool get isRunning => _streamable != null;

  /// 实际绑定端口（端口冲突/被占时与 [port] 不同，仅 start 后有效）。
  int get boundPort => _streamable?.boundPort ?? port;

  /// agent 连接地址。
  String get url => 'http://127.0.0.1:$boundPort/mcp';

  Future<void> start() async {
    if (_streamable != null) return;
    final streamable = StreamableMcpServer(
      serverFactory: (sessionId) => _buildServer(),
      host: '127.0.0.1',
      port: port,
      path: '/mcp',
      eventStore: InMemoryEventStore(),
      enableDnsRebindingProtection: true,
      allowedHosts: const {'localhost', '127.0.0.1'},
    );
    await streamable.start();
    _streamable = streamable;
    port = streamable.boundPort;
  }

  Future<void> stop() async {
    final streamable = _streamable;
    _streamable = null;
    if (streamable != null) {
      await streamable.stop();
    }
  }

  /// 每个连接会话一个 McpServer 实例（StreamableMcpServer 按 session 工厂创建）。
  McpServer _buildServer() {
    final server = McpServer(
      const Implementation(name: 'zizai-mcp', version: '1.0.0'),
      options: const McpServerOptions(protocol: McpProtocol.stable),
    );
    for (final tool in buildZizaiMcpTools(
      db,
      snapshots: snapshots,
      onWrite: onWrite,
    )) {
      server.registerTool(
        tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
        callback: (args, extra) async {
          final result = await tool.handler(args);
          return CallToolResult(
            content: [TextContent(text: result.content)],
            isError: result.isError,
          );
        },
      );
    }
    return server;
  }
}
