import 'package:pw_server/pw_server.dart';
import 'package:test/test.dart';

void main() {
  test('parses --web-dir', () {
    final options = DaemonOptions.fromArgs([
      '--port',
      '0',
      '--web-dir',
      'build/web',
    ]);

    expect(options.port, 0);
    expect(options.webDir, 'build/web');
  });

  test('rejects --web-dir without a value', () {
    expect(() => DaemonOptions.fromArgs(['--web-dir']), throwsFormatException);
  });
}
