import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String logFile;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pw_api_log_cli');
    logFile = p.join(temp.path, 'api-access.log');
    File(logFile).writeAsStringSync(
      [
        jsonEncode(_entry(status: 200, durationMs: 10)),
        jsonEncode(
          _entry(status: 500, durationMs: 20, error: 'internal_error'),
        ),
        jsonEncode(_entry(status: 401, durationMs: 5, auth: 'invalid')),
        jsonEncode(_entry(status: 200, durationMs: 2000)),
      ].join('\n'),
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('problems finds errors, unauthorized and slow requests', () {
    final result = _run(['problems', '--file=$logFile', '--slow-ms=1000']);

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, contains('Проблемных записей: 3'));
  });

  test('filter returns matching JSONL', () {
    final result = _run([
      'filter',
      '--file=$logFile',
      '--status=401',
      '--json',
    ]);

    expect(result.exitCode, 0, reason: result.stderr);
    final lines = (result.stdout as String).trim().split('\n');
    expect(lines, hasLength(1));
    expect(jsonDecode(lines.single)['status'], 401);
  });

  test('summary shows all entries', () {
    final result = _run(['summary', '--file=$logFile', '--top=1']);

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.stdout, contains('Записей: 4'));
  });
}

ProcessResult _run(List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  ['run', 'bin/api_log.dart', ...args],
  workingDirectory: Directory.current.path,
);

Map<String, Object?> _entry({
  required int status,
  required int durationMs,
  String auth = 'ok',
  String? error,
}) => {
  'ts': '2026-11-12T10:00:00.000Z',
  'event': 'api.request',
  'requestId': 'abc',
  'method': 'GET',
  'path': '/api/v1/chats',
  'status': status,
  'durationMs': durationMs,
  'remote': '127.0.0.1',
  'auth': auth,
  'token': null,
  'error': error,
};
