import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zi_zai/core/app_logger.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zizai_logger');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('按 JSON Lines 写入启动信息与异常上下文', () async {
    final logger = await AppLogger.create(tempDir);
    await logger.info('app.starting', data: {'version': '1.2.3'});
    await logger.error(
      'update.failed',
      StateError('network denied'),
      StackTrace.current,
    );

    final lines = await File(logger.path).readAsLines();
    expect(lines, hasLength(2));
    final first = jsonDecode(lines.first) as Map<String, dynamic>;
    final second = jsonDecode(lines.last) as Map<String, dynamic>;
    expect(first['event'], 'app.starting');
    expect(first['data'], {'version': '1.2.3'});
    expect(second['level'], 'error');
    expect(second['error'], contains('network denied'));
    expect(second['stackTrace'], isNotEmpty);
  });

  test('超过大小后滚动并限制保留文件数', () async {
    final logger = await AppLogger.create(
      tempDir,
      maxBytes: 180,
      retainedFiles: 3,
    );
    for (var index = 0; index < 12; index++) {
      await logger.info('rotation.test', message: '记录$index-${'x' * 80}');
    }

    final files = await logger.files();
    expect(files.length, lessThanOrEqualTo(3));
    expect(File(logger.path).existsSync(), isTrue);
    expect(File('${logger.path}.1').existsSync(), isTrue);
    expect(File('${logger.path}.3').existsSync(), isFalse);
  });
}
