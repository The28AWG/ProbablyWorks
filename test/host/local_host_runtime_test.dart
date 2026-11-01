import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/local_host_runtime.dart';
import 'package:probably_works/host/process_control.dart';

class _RunResult {
  _RunResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    this.pid,
    this.connectionLost = false,
  });

  final String stdout;
  final String stderr;
  final int? exitCode;
  final int? pid;
  final bool connectionLost;
}

Future<_RunResult> _collect(Stream<ExecEvent> events) async {
  final out = StringBuffer();
  final err = StringBuffer();
  int? pid;
  int? code;
  var lost = false;
  await for (final event in events) {
    switch (event) {
      case ExecStarted e:
        pid = e.pid;
      case ExecStdout e:
        out.write(utf8.decode(e.bytes));
      case ExecStderr e:
        err.write(utf8.decode(e.bytes));
      case ExecDone e:
        code = e.exitCode;
        lost = e.connectionLost;
    }
  }
  return _RunResult(
    stdout: out.toString(),
    stderr: err.toString(),
    exitCode: code,
    pid: pid,
    connectionLost: lost,
  );
}

/// Запускает команду, сообщает pid по первому ExecStarted и возвращает будущий ExecDone.
({Future<int> pid, Future<ExecDone> done}) _startTracked(
  Stream<ExecEvent> events,
) {
  final pid = Completer<int>();
  final done = Completer<ExecDone>();
  events.listen(
    (event) {
      switch (event) {
        case ExecStarted e:
          if (!pid.isCompleted) pid.complete(e.pid);
        case ExecDone e:
          if (!done.isCompleted) done.complete(e);
        case ExecStdout() || ExecStderr():
          break;
      }
    },
    onDone: () {
      if (!done.isCompleted) {
        done.completeError(StateError('stream closed without ExecDone'));
      }
    },
  );
  return (pid: pid.future, done: done.future);
}

void main() {
  final runtime = LocalHostRuntime(os: HostOs.posix);

  test('streams stdout and reports exit code', () async {
    final result = await _collect(
      runtime.run('echo hello; echo oops 1>&2; exit 3'),
    );
    expect(result.stdout, 'hello\n');
    expect(result.stderr, 'oops\n');
    expect(result.exitCode, 3);
    expect(result.pid, isNotNull);
    expect(result.connectionLost, isFalse);
  });

  test('runs in the requested working directory', () async {
    final dir = Directory.systemTemp.createTempSync('pw_cwd');
    addTearDown(() => dir.deleteSync(recursive: true));
    final result = await _collect(runtime.run('pwd', cwd: dir.path));
    expect(result.stdout.trim(), dir.resolveSymbolicLinksSync());
  });

  test('keeps stdout free of the pid marker', () async {
    final result = await _collect(runtime.run('printf "a\\nb\\n"'));
    expect(result.stdout, 'a\nb\n');
  });

  test('ExecStarted pid is the process group leader, so kill by pid stops the command', () async {
    final tracked = _startTracked(runtime.run('sleep 30'));
    final pid = await tracked.pid.timeout(const Duration(seconds: 5));
    await runtime.killProcess(pid, force: true);
    final done = await tracked.done.timeout(const Duration(seconds: 10));
    expect(done.exitCode, isNot(0));
  });

  test('kill of the process group also stops background children', () async {
    final pidFile = File(
      '${Directory.systemTemp.path}/pw_child_${DateTime.now().microsecondsSinceEpoch}.pid',
    );
    addTearDown(() {
      if (pidFile.existsSync()) pidFile.deleteSync();
    });
    final tracked = _startTracked(
      runtime.run('sleep 60 & echo \$! > ${pidFile.path}; wait'),
    );
    final pid = await tracked.pid.timeout(const Duration(seconds: 5));
    while (!pidFile.existsSync() || pidFile.readAsStringSync().trim().isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final childPid = int.parse(pidFile.readAsStringSync().trim());

    await runtime.killProcess(pid);
    await tracked.done.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final alive = Process.runSync('kill', ['-0', '$childPid']).exitCode == 0;
    expect(
      alive,
      isFalse,
      reason: 'child process must die with the process group',
    );
  });

  test('ProcessControl builds posix kill for group and plain pid', () {
    final control = ProcessControl(HostOs.posix);
    expect(control.killCommand(42), contains('-- -42'));
    expect(control.wrap('ls'), contains('exec setsid -w sh -c '));
  });

  test('ProcessControl macOS wrap uses child-tree kill', () {
    final control = ProcessControl(HostOs.macos);
    expect(control.wrap('ls'), startsWith('sh -c '));
    expect(control.killCommand(7), contains('pgrep -P'));
  });
}
