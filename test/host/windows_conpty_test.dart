import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/host_terminal.dart';
import 'package:pw_agent/host/local_host_runtime.dart';

/// Проверка ConPTY на настоящей Windows-машине.
///
/// Тест идёт через тот же `LocalHostRuntime.openTerminal`, что и продукт:
/// `cmd /d /s /c`, окружение хоста и рабочая директория. Запускается только
/// на Windows; на CI это отдельный шаг в job `windows-assembly`.
void main() {
  final skip = Platform.isWindows
      ? null
      : 'Windows ConPTY test runs only on Windows';

  test(
    'runs cmd in ConPTY and reports output and exit code',
    skip: skip,
    () async {
      expect(LocalHostRuntime(os: HostOs.windows).hasTerminal, isTrue);

      final result = await _run('echo conpty-ok & exit /b 3');

      expect(result.output, contains('conpty-ok'));
      expect(result.exitCode, 3);
    },
  );

  test('passes the host environment into ConPTY', skip: skip, () async {
    final result = await _run(
      'echo env=%PW_CONPTY_TEST%',
      environment: const {'PW_CONPTY_TEST': 'value-42'},
    );

    expect(result.output, contains('env=value-42'));
    expect(result.exitCode, 0);
  });

  test('opens ConPTY in the requested working directory', skip: skip, () async {
    final dir = Directory.systemTemp.createTempSync('pw_conpty_cwd');
    addTearDown(() => dir.deleteSync(recursive: true));

    final result = await _run('cd', cwd: dir.path);

    // cmd может показать путь в формате 8.3 (RUNNER~1), поэтому проверяем
    // уникальное имя временного каталога, а не весь длинный путь.
    expect(
      result.output.toLowerCase(),
      contains(p.basename(dir.path).toLowerCase()),
    );
    expect(result.exitCode, 0);
  });
}

/// Запускает команду через локальный Host, как в приложении.
Future<({String output, int? exitCode})> _run(
  String script, {
  Map<String, String> environment = const {},
  String? cwd,
}) async {
  final runtime = LocalHostRuntime(
    os: HostOs.windows,
    environment: environment,
  );
  final terminal = await runtime.openTerminal(
    script,
    cwd: cwd,
    columns: 100,
    rows: 40,
  );
  return _drain(terminal);
}

/// Читает весь вывод терминала до завершения и возвращает код выхода.
Future<({String output, int? exitCode})> _drain(HostTerminal terminal) async {
  final out = BytesBuilder();
  await for (final chunk in terminal.attach()) {
    out.add(chunk);
  }
  return (
    output: utf8.decode(out.takeBytes(), allowMalformed: true),
    exitCode: await terminal.exitCode,
  );
}
