/// 本地 MCP 服务控制器：开关/端口持久化 + 服务生命周期。
///
/// settings 键：`mcp.enabled` / `mcp.port`（与 backup./sync. 同前缀约定）。
/// 启动时若 enabled → 自动起服务；dispose 时停服务。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/db.dart';
import '../core/mcp/mcp_server.dart';
import '../core/snapshot_history.dart';
import '../core/mcp/writing_skill.dart';

class McpController extends ChangeNotifier {
  McpController(
    this._db, {
    SnapshotHistory? snapshots,
    int initialPort = McpController.defaultPort,
    Future<void> Function()? onWrite,
  }) : _server = ZizaiMcpServer(
          db: _db,
          snapshots: snapshots,
          port: initialPort,
          onWrite: onWrite,
        );

  static const String kEnabledKey = 'mcp.enabled';
  static const String kPortKey = 'mcp.port';
  static const int defaultPort = 8765;

  final Db _db;
  final ZizaiMcpServer _server;

  bool _enabled = false;
  bool _starting = false;
  bool _running = false;
  String? _lastError;

  bool get enabled => _enabled;

  /// 正在启动中（设置页按钮 loading 态）。
  bool get starting => _starting;

  bool get running => _running;

  int get port => _server.port;

  /// 运行中才有地址；未运行返回 null。
  String? get url => _running ? _server.url : null;

  String? get lastError => _lastError;

  /// 启动时装配：读持久化配置，enabled 则起服务。
  Future<void> init() async {
    _enabled = (await _db.getSetting(kEnabledKey)) == 'true';
    final portValue = await _db.getSetting(kPortKey);
    if (portValue != null) {
      final parsed = int.tryParse(portValue);
      if (parsed != null && parsed >= 1024 && parsed <= 65535) {
        _server.port = parsed;
      }
    }
    if (_enabled) {
      await _start();
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await _db.setSetting(kEnabledKey, value.toString());
    if (value) {
      await _start();
    } else {
      await _stop();
    }
    notifyListeners();
  }

  Future<void> setPort(int value) async {
    // 0 = 自动分配空闲端口（start 后以 boundPort 为准）。
    final next = value.clamp(0, 65535);
    if (next == _server.port) return;
    _server.port = next;
    await _db.setSetting(kPortKey, next.toString());
    if (_running) {
      // 端口变更 → 重启服务使新端口生效。
      await _stop();
      await _start();
    }
    notifyListeners();
  }

  /// 复制 skill 内容到剪贴板的素材（设置页按钮调用）。
  String get skillText => kZizaiWritingSkill;

  Future<void> _start() async {
    _starting = true;
    _lastError = null;
    notifyListeners();
    try {
      await _server.start();
      _running = true;
    } catch (e) {
      _lastError = '启动失败：$e';
      _running = false;
    } finally {
      _starting = false;
    }
  }

  Future<void> _stop() async {
    await _server.stop();
    _running = false;
    _lastError = null;
  }

  @override
  void dispose() {
    unawaited(_server.stop());
    super.dispose();
  }
}
