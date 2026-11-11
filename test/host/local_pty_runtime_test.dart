import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:portable_pty/portable_pty.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/host_runtime.dart';
import 'package:pw_agent/host/host_terminal.dart';
import 'package:pw_agent/host/local_host_runtime.dart';

/// Настоящий PTY через нативную библиотеку portable_pty (Rust, собирается hook-ом пакета).
///
/// Тесты пропускаются, если нативная библиотека не открывается, и на Windows: там PTY без
/// неблокирующего режима пока не реализован (см. portable_pty_launcher.dart).
final _skip = Platform.isWindows
    ? 'portable_pty launcher is POSIX-only for now'
    : _ptyAvailable()
    ? null
    : 'portable_pty native library is not available';

bool _ptyAvailable() {
  try {
    PortablePty.open().close();
    return true;
  } on Object {
    return false;
  }
}

/// Читает весь вывод терминала до его завершения и возвращает код выхода.
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

void main() {
  final runtime = LocalHostRuntime(os: HostOs.posix);

  test('command runs on a real TTY', skip: _skip, () async {
    final terminal = await runtime.openTerminal('[ -t 0 ] && echo tty');
    final result = await _drain(terminal);
    expect(result.output, contains('tty'));
    expect(result.exitCode, 0);
  });

  test('terminal opens with the requested size', skip: _skip, () async {
    final terminal = await runtime.openTerminal(
      'stty size',
      columns: 100,
      rows: 40,
    );
    final result = await _drain(terminal);
    expect(result.output, contains('40 100'));
  });

  test('resize reaches the running command', skip: _skip, () async {
    final terminal = await runtime.openTerminal(
      'sleep 1; stty size',
      columns: 100,
      rows: 40,
    );
    terminal.resize(90, 33);
    final result = await _drain(terminal);
    expect(result.output, contains('33 90'));
  });

  test(
    'input written to the terminal reaches the command',
    skip: _skip,
    () async {
      final terminal = await runtime.openTerminal(
        'read line; echo "got:\$line"',
      );
      terminal.write(Uint8List.fromList(utf8.encode('hello\r')));
      final result = await _drain(terminal);
      expect(result.output, contains('got:hello'));
    },
  );

  test(
    'pagers are disabled so git does not block on less',
    skip: _skip,
    () async {
      final terminal = await runtime.openTerminal('echo "pager=\$PAGER"');
      final result = await _drain(terminal);
      expect(result.output, contains('pager=cat'));
    },
  );

  test(
    'colour codes from the command are kept in the raw output',
    skip: _skip,
    () async {
      final terminal = await runtime.openTerminal(
        r"printf '\033[31mred\033[0m\n'",
      );
      final result = await _drain(terminal);
      expect(result.output, contains('\x1b[31mred\x1b[0m'));
    },
  );

  test('runs in the requested working directory', skip: _skip, () async {
    final dir = Directory.systemTemp.createTempSync('pw_pty_cwd');
    addTearDown(() => dir.deleteSync(recursive: true));
    final terminal = await runtime.openTerminal('pwd', cwd: dir.path);
    final result = await _drain(terminal);
    expect(result.output, contains(dir.resolveSymbolicLinksSync()));
  });

  test(
    'exit code is reported and output is replayed to a late subscriber',
    skip: _skip,
    () async {
      final terminal = await runtime.openTerminal('echo once; exit 3');
      final first = await _drain(terminal);
      expect(first.exitCode, 3);
      final late = await _drain(terminal);
      expect(late.output, contains('once'));
    },
  );

  test(
    'pid from the marker is known and kill by pid stops the terminal command',
    skip: _skip,
    () async {
      final terminal = await runtime.openTerminal('sleep 30');
      final pid = await terminal.pid.timeout(const Duration(seconds: 5));
      expect(pid, isNotNull);
      await runtime.killProcess(pid!, force: true);
      final result = await _drain(terminal)
          .timeout(const Duration(seconds: 10));
      expect(result.exitCode, isNot(0));
    },
  );

  test(
    'execEventsOf reports pid, output and exit code like run()',
    skip: _skip,
    () async {
      final terminal = await runtime.openTerminal('echo hi; exit 4');
      final events = await execEventsOf(terminal).toList();
      expect(events.whereType<ExecStarted>(), isNotEmpty);
      final output = events
          .whereType<ExecStdout>()
          .map((e) => utf8.decode(e.bytes, allowMalformed: true))
          .join();
      expect(output, contains('hi'));
      expect(events.last, isA<ExecDone>());
      expect((events.last as ExecDone).exitCode, 4);
    },
  );
}
