import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/host_environment.dart';

void main() {
  const command = 'echo hello';

  test('префикс POSIX экранирует кавычку и не меняет исходную команду', () {
    final script = withHostEnvironment(
      command,
      os: HostOs.posix,
      environment: const {'TOKEN': "a'b"},
    );

    expect(script, "export TOKEN='a'\\''b';echo hello");
    expect(command, 'echo hello');
  });

  test('префикс macOS совпадает с POSIX', () {
    expect(
      withHostEnvironment(
        command,
        os: HostOs.macos,
        environment: const {'TOKEN': "a'b"},
      ),
      "export TOKEN='a'\\''b';echo hello",
    );
  });

  test('префикс Windows экранирует кавычку в стиле PowerShell', () {
    expect(
      withHostEnvironment(
        command,
        os: HostOs.windows,
        environment: const {'TOKEN': "a'b"},
      ),
      "\$env:TOKEN='a''b';echo hello",
    );
  });

  test('пустая карта оставляет скрипт без префикса', () {
    expect(
      withHostEnvironment(command, os: HostOs.posix, environment: const {}),
      command,
    );
  });

  test('в терминале TERM стоит последним и не затирается картой хоста', () {
    final environment = localSessionEnvironment(
      machine: const {'PATH': '/usr/bin', 'HOME': '/home/me'},
      host: const {'TOKEN': 'secret-value', 'TERM': 'dumb', 'PATH': '/evil'},
      terminal: true,
    );

    expect(environment['TOKEN'], 'secret-value');
    expect(environment['HOME'], '/home/me');
    expect(environment['PATH'], '/evil');
    expect(environment['TERM'], 'xterm-256color');
  });
}
