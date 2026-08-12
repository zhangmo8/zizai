/// 本地诊断日志：JSON Lines、串行写入、按大小滚动保留。
library;

import 'dart:convert';
import 'dart:io';

enum LogLevel { info, warning, error }

class AppLogger {
  AppLogger._(
    this.directory, {
    required this.maxBytes,
    required this.retainedFiles,
  }) : _file = File('${directory.path}${Platform.pathSeparator}zi-zai.log');

  final Directory directory;
  final int maxBytes;
  final int retainedFiles;
  final File _file;
  Future<void> _writeQueue = Future<void>.value();

  String get path => _file.path;

  static Future<AppLogger> create(
    Directory appSupportDir, {
    int maxBytes = 1024 * 1024,
    int retainedFiles = 5,
  }) async {
    final directory = Directory(
      '${appSupportDir.path}${Platform.pathSeparator}logs',
    );
    await directory.create(recursive: true);
    return AppLogger._(
      directory,
      maxBytes: maxBytes,
      retainedFiles: retainedFiles,
    );
  }

  Future<void> info(
    String event, {
    String? message,
    Map<String, Object?>? data,
  }) => _enqueue(LogLevel.info, event, message: message, data: data);

  Future<void> warning(
    String event, {
    String? message,
    Map<String, Object?>? data,
  }) => _enqueue(LogLevel.warning, event, message: message, data: data);

  Future<void> error(
    String event,
    Object error,
    StackTrace stackTrace, {
    String? message,
    Map<String, Object?>? data,
  }) => _enqueue(
    LogLevel.error,
    event,
    message: message,
    error: error,
    stackTrace: stackTrace,
    data: data,
  );

  Future<List<File>> files() async {
    if (!await directory.exists()) return const [];
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.contains('zi-zai.log'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<void> _enqueue(
    LogLevel level,
    String event, {
    String? message,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) {
    final record = <String, Object?>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'level': level.name,
      'event': event,
      'message': ?message,
      if (error != null) 'error': error.toString(),
      if (stackTrace != null) 'stackTrace': stackTrace.toString(),
      'data': ?data,
    };
    final line = '${jsonEncode(record)}\n';
    _writeQueue = _writeQueue.then((_) => _write(line)).catchError((_) {
      // 诊断日志绝不能反过来导致业务流程失败。
    });
    return _writeQueue;
  }

  Future<void> _write(String line) async {
    await directory.create(recursive: true);
    final incomingBytes = utf8.encode(line).length;
    if (await _file.exists() &&
        await _file.length() + incomingBytes > maxBytes) {
      await _rotate();
    }
    await _file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  Future<void> _rotate() async {
    if (retainedFiles <= 1) {
      await _file.delete();
      return;
    }
    final oldest = File('${_file.path}.${retainedFiles - 1}');
    if (await oldest.exists()) await oldest.delete();
    for (var index = retainedFiles - 2; index >= 1; index--) {
      final source = File('${_file.path}.$index');
      if (await source.exists()) {
        await source.rename('${_file.path}.${index + 1}');
      }
    }
    if (await _file.exists()) await _file.rename('${_file.path}.1');
  }
}
