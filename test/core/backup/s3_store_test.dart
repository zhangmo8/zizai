/// S3Store（R2 直连）测试：SigV4 签名基准（Python 独立实现交叉验证）+ 往返。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zi_zai/core/backup/s3_store.dart';

/// 固定输入下由独立实现（Python SigV4）算出的基准签名。
/// 与 s3_store.dart 同一 canonical request 构造：region=auto、service=s3、
/// signed headers = host;x-amz-content-sha256;x-amz-date。
const _fixedClock = '20260806T123456Z';
const _putSignature =
    '7393627c043c5b0076fccd6bb4722c3dbc3121e1399dda9c2f0c7309f3545076';
const _getSignature =
    '7997c2df9f4d918adf675943a9e9afe10d8e77b518635c2a88ceaf0e4479a880';
const _putPayloadHash =
    'f2dfa540bf318617061062c6fe0936fe39076a64a432ea9c94d181ded01d04ec';
const _emptyHash =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

DateTime _fixedNow() => DateTime.utc(2026, 8, 6, 12, 34, 56);

S3Store _store(http.Client client) => S3Store(
      accountId: 'testaccount',
      bucket: 'mybucket',
      accessKey: 'AKIDEXAMPLE',
      secretKey: 'SECRETEXAMPLE',
      httpClient: client,
      clock: _fixedNow,
    );

void main() {
  test('PUT：SigV4 签名与独立基准一致，payload hash 正确', () async {
    late http.Request captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response('', 200);
    });
    await _store(client).putObject('zizai-backup.json', utf8.encode('hello backup'));

    expect(captured.method, 'PUT');
    expect(captured.url.toString(),
        'https://testaccount.r2.cloudflarestorage.com/mybucket/zizai-backup.json');
    expect(captured.headers['x-amz-content-sha256'], _putPayloadHash);
    expect(captured.headers['x-amz-date'], _fixedClock);
    expect(captured.headers['authorization'],
        'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260806/auto/s3/aws4_request, '
        'SignedHeaders=host;x-amz-content-sha256;x-amz-date, '
        'Signature=$_putSignature');
    expect(captured.bodyBytes, utf8.encode('hello backup'));
  });

  test('GET：空 payload hash + 基准签名；往返取回原数据', () async {
    final bytes = utf8.encode('快照内容 {}');
    final client = MockClient((req) async {
      expect(req.method, 'GET');
      expect(req.headers['x-amz-content-sha256'], _emptyHash);
      expect(req.headers['authorization'],
          contains('Signature=$_getSignature'));
      return http.Response.bytes(bytes, 200);
    });
    final got = await _store(client).getObject('zizai-backup.json');
    expect(got, isNotNull);
    expect(got, bytes);
  });

  test('GET 404 → null；非 200 → S3Exception', () async {
    final notFound = MockClient((_) async => http.Response('Not Found', 404));
    expect(await _store(notFound).getObject('x'), isNull);

    final serverError = MockClient((_) async => http.Response('boom', 500));
    expect(() => _store(serverError).getObject('x'),
        throwsA(isA<S3Exception>()));
  });

  test('PUT 非 200 → S3Exception', () async {
    final client = MockClient((_) async => http.Response('denied', 403));
    expect(() => _store(client).putObject('k', const []),
        throwsA(isA<S3Exception>()));
  });

  test('Uint8List 往返（真实 body 非文本场景）', () async {
    final payload = Uint8List.fromList(List.generate(300, (i) => i % 251));
    final client = MockClient((req) async {
      expect(req.method, 'PUT');
      return http.Response('', 200);
    });
    final store = _store(client);
    await store.putObject('k', payload);
    // GET 走另一个 mock
    final getClient = MockClient((_) async => http.Response.bytes(payload, 200));
    final got = await _store(getClient).getObject('k');
    expect(got, payload);
  });
}
