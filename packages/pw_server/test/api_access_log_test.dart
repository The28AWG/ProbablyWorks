import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pw_server/src/api/api_access_log.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pw_api_log');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('writes JSONL entries and a short token fingerprint', () {
    final directory = Directory(p.join(temp.path, 'logs'));
    final log = ApiAccessLog(directory);
    final fingerprint = ApiAccessLog.fingerprint('secret-token');

    expect(fingerprint, hasLength(8));
    expect(fingerprint, isNot('secret-token'));

    log.write({
      'event': 'api.request',
      'method': 'GET',
      'path': '/api/v1/chats',
      'status': 200,
      'token': fingerprint,
    });

    final entries = _entries(directory);
    expect(entries, hasLength(1));
    expect(entries.single['event'], 'api.request');
    expect(entries.single['token'], fingerprint);
    if (!Platform.isWindows) {
      expect(
        File(p.join(directory.path, 'api-access.log')).statSync().mode & 0x1FF,
        0x180,
      );
      expect(directory.statSync().mode & 0x1FF, 0x1C0);
    }
  });

  test('rotates the access log', () {
    final log = ApiAccessLog(temp, maxBytes: 60, keepFiles: 2);
    for (var i = 0; i < 6; i++) {
      log.write({'event': 'api.request', 'index': i});
    }

    final file = File(p.join(temp.path, 'api-access.log'));
    final rotated = File('${file.path}.1');
    expect(file.existsSync(), isTrue);
    expect(rotated.existsSync(), isTrue);
    expect(_entries(temp).length, lessThan(6));
  });
}

List<Map<String, dynamic>> _entries(Directory directory) {
  final file = File(p.join(directory.path, 'api-access.log'));
  if (!file.existsSync()) return const [];
  return [
    for (final line in file.readAsLinesSync())
      if (line.isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
  ];
}
