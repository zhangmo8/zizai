/// 协议兼容的测试服务器（内存版 Worker）：双设备模拟用。
/// 与 worker/src/index.ts 同一 wire contract（docs/app/sync.md §4）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:zi_zai/core/sync/protocol.dart';

/// 内存 envelope 库 + 服务器时间戳 + since 过滤。
class FakeSyncServer {
  FakeSyncServer({this.token = 'test-token', this.protocol = syncProtocolVersion});

  final String token;
  final int protocol;
  final Map<String, Map<String, dynamic>> store = {};
  // 与真实时钟同量级，保证与本地 updatedAt（真实 epoch）可比较。
  int clock = DateTime.now().millisecondsSinceEpoch;

  int _tick() => clock += 1000; // 每次请求时间戳严格递增

  static const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

  http.Client client() => MockClient((request) async {
        final auth = request.headers['authorization'] ?? '';
        if (auth != 'Bearer $token') {
          return http.Response(jsonEncode({'error': 'unauthorized'}), 401,
              headers: _jsonHeaders);
        }
        if (request.headers['x-sync-protocol'] != '$protocol') {
          return http.Response(jsonEncode({'error': 'protocol_mismatch'}), 409,
              headers: _jsonHeaders);
        }
        final path = request.url.path;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (path == '/sync/push') {
          if (body['schemaVersion'] != syncSchemaVersion) {
            return http.Response(jsonEncode({'error': 'schema_mismatch'}), 409,
                headers: _jsonHeaders);
          }
          final serverTime = _tick();
          final applied = <Map<String, dynamic>>[];
          for (final raw in (body['blobs'] as List)) {
            final envelope = (raw as Map).cast<String, dynamic>();
            final id = envelope['id']! as String;
            envelope['updatedAt'] = serverTime; // 服务器时间戳覆盖
            store[id] = envelope;
            applied.add({'id': id, 'updatedAt': serverTime});
          }
          return http.Response(
              jsonEncode({'serverTime': serverTime, 'applied': applied}), 200,
              headers: _jsonHeaders);
        }
        if (path == '/sync/pull') {
          final since = (body['since'] as num).toInt();
          final serverTime = _tick();
          final blobs = [
            for (final e in store.values)
              if ((e['updatedAt']! as int) > since) e,
          ];
          return http.Response(
              jsonEncode({'serverTime': serverTime, 'blobs': blobs}), 200,
              headers: _jsonHeaders);
        }
        return http.Response(jsonEncode({'error': 'not_found'}), 404,
            headers: _jsonHeaders);
      });
}
