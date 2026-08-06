/// 极简 S3 兼容客户端（Cloudflare R2）：AWS SigV4 签名的 PUT / GET。
///
/// 只实现备份所需两个操作；region 固定 `auto`（R2 无地域概念）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// S3 请求失败（HTTP 非 200/404）。
class S3Exception implements Exception {
  const S3Exception(this.message);

  final String message;

  @override
  String toString() => 'S3Exception($message)';
}

/// R2 对象存储直连（凭据由用户在设置页配置，仅存本地，不上传）。
class S3Store {
  S3Store({
    required this.accountId,
    required this.bucket,
    required this.accessKey,
    required this.secretKey,
    http.Client? httpClient,
    DateTime Function()? clock,
  })  : _http = httpClient ?? http.Client(),
        _clock = clock ?? DateTime.now;

  final String accountId;
  final String bucket;
  final String accessKey;
  final String secretKey;
  final http.Client _http;
  final DateTime Function() _clock;

  static const _service = 's3';
  static const _region = 'auto';

  Uri _endpoint(String key) => Uri.parse(
      'https://$accountId.r2.cloudflarestorage.com/$bucket/$key');

  /// 上传对象（覆盖写；R2 版本控制负责留历史）。
  Future<void> putObject(String key, List<int> bytes) async {
    final uri = _endpoint(key);
    final payloadHash = _sha256Hex(bytes);
    final headers = _signedHeaders('PUT', uri, payloadHash);
    final res = await _http.put(uri, headers: headers, body: bytes);
    if (res.statusCode != 200) {
      throw S3Exception('上传失败 (HTTP ${res.statusCode})');
    }
  }

  /// 下载对象；云端不存在（404）返回 null。
  Future<Uint8List?> getObject(String key) async {
    final uri = _endpoint(key);
    final headers = _signedHeaders('GET', uri, _sha256Hex(const []));
    final res = await _http.get(uri, headers: headers);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw S3Exception('下载失败 (HTTP ${res.statusCode})');
    }
    return res.bodyBytes;
  }

  // ── AWS SigV4 ─────────────────────────────────────────────

  Map<String, String> _signedHeaders(String method, Uri uri, String payloadHash) {
    final now = _clock().toUtc();
    final amzDate = _fmtAmzDate(now);
    final dateStamp = _fmtDateStamp(now);
    final host = uri.host;
    final canonicalUri = uri.path; // 无 query、key 无转义需求
    final canonicalQuery = '';
    const signedHeaderNames = 'host;x-amz-content-sha256;x-amz-date';
    final canonicalHeaders =
        'host:$host\nx-amz-content-sha256:$payloadHash\nx-amz-date:$amzDate\n';
    final scope = '$dateStamp/$_region/$_service/aws4_request';
    final canonicalRequest = [
      method,
      canonicalUri,
      canonicalQuery,
      canonicalHeaders,
      signedHeaderNames,
      payloadHash,
    ].join('\n');
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      _sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');
    final signature = _hmacHex(_signingKey(dateStamp), stringToSign);
    return {
      'host': host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      'authorization':
          'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, '
          'SignedHeaders=$signedHeaderNames, Signature=$signature',
    };
  }

  List<int> _signingKey(String dateStamp) {
    final kDate = Hmac(sha256, utf8.encode('AWS4$secretKey'))
        .convert(utf8.encode(dateStamp))
        .bytes;
    final kRegion =
        Hmac(sha256, kDate).convert(utf8.encode(_region)).bytes;
    final kService =
        Hmac(sha256, kRegion).convert(utf8.encode(_service)).bytes;
    return Hmac(sha256, kService)
        .convert(utf8.encode('aws4_request'))
        .bytes;
  }

  String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  String _hmacHex(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).toString();

  String _fmtDateStamp(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}';
  }

  String _fmtAmzDate(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${_fmtDateStamp(utc)}T${two(utc.hour)}'
        '${two(utc.minute)}${two(utc.second)}Z';
  }
}
