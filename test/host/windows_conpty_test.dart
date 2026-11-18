import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/flutter_pty_launcher.dart';
import 'package:pw_agent/host/host_environment.dart';
import 'package:pw_agent/host/host_terminal.dart';
import 'package:pw_agent/host/process_control.dart';
import 'package:pw_agent/host/shell_adapter.dart';

/// Проверка ConPTY на настоящей Windows-машине.
///
/// Локальный терминал на Windows пока выключен в `LocalHostRuntime`, поэтому
/// тест запускает `FlutterPtyLauncher` напрямую через тот же `cmd /c`, который
/// использует продукт. Запускается только на Windows; на CI это отдельный шаг
/// в job `windows-assembly`.
void main() {
  final skip = Platform.isWindows
      ? null
      : 'Windows ConPTY test runs only on Windows';

  test(
    'runs cmd in ConPTY and reports output and exit code',
    skip: skip,
    () async {
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

    expect(
      result.output.toLowerCase(),
      contains(dir.resolveSymbolicLinksSync().toLowerCase()),
    );
    expect(result.exitCode, 0);
  });
}

/// Запускает команду так же, как `LocalHostRuntime.openTerminal`.
Future<({String output, int? exitCode})> _run(
  String script, {
  Map<String, String> environment = const {},
  String? cwd,
}) async {
  final control = ProcessControl(HostOs.windows);
  final fullScript = cwd == null
      ? script
      : '${ShellAdapter(HostOs.windows).cd(cwd)} && $script';
  final channel = await const FlutterPtyLauncher().start(
    control.shellExecutable,
    control.terminalShellArgs(control.wrapTerminal(fullScript)),
    environment: localSessionEnvironment(
      machine: Platform.environment,
      host: environment,
      terminal: true,
    ),
    columns: 100,
    rows: 40,
  );
  final terminal = PtyHostTerminal(channel, markers: control.hasPidMarker);
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
