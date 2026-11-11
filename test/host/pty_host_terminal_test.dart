import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/host/host_runtime.dart';
import 'package:pw_agent/host/host_terminal.dart';
import 'package:pw_agent/host/process_control.dart';

/// Фейковый PTY: вывод и код выхода задаёт тест, ввод и размер записываются.
class _FakeChannel implements PtyChannel {
  _FakeChannel({this.knownPid});

  final _output = StreamController<Uint8List>();
  final _exit = Completer<int?>();
  final written = <Uint8List>[];
  final resizes = <(int, int)>[];

  @override
  final int? knownPid;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  void write(Uint8List data) => written.add(data);

  @override
  void resize(int columns, int rows) => resizes.add((columns, rows));

  @override
  Future<int?> get exitCode => _exit.future;

  void emit(String text) => _output.add(Uint8List.fromList(utf8.encode(text)));

  Future<void> closeOutput() => _output.close();

  void finish(int? code) => _exit.complete(code);
}

Future<String> _readAll(HostTerminal terminal) async {
  final out = BytesBuilder();
  await for (final chunk in terminal.attach()) {
    out.add(chunk);
  }
  return utf8.decode(out.takeBytes());
}

void main() {
  test(
    'pid comes from the marker line and is stripped from the output',
    () async {
      final channel = _FakeChannel();
      final terminal = PtyHostTerminal(channel, markers: true);
      channel
        ..emit('PW_PID:4242\nhello\r\n')
        ..finish(0);
      await channel.closeOutput();
      expect(await terminal.pid, 4242);
      expect(await _readAll(terminal), 'hello\r\n');
    },
  );

  test(
    'exit marker is removed, acknowledged, and sets the exit code',
    () async {
      final channel = _FakeChannel();
      final terminal = PtyHostTerminal(channel, markers: true);
      channel
        ..emit('PW_PID:1\nout\r\n\x1b]PW;EXIT=3\x07')
        ..finish(null);
      await channel.closeOutput();
      expect(await _readAll(terminal), 'out\r\n');
      expect(channel.written.map(utf8.decode), ['\n']);
      expect(await terminal.exitCode, 3);
    },
  );

  test('exit marker split across chunks is still recognised', () async {
    final channel = _FakeChannel();
    final terminal = PtyHostTerminal(channel, markers: true);
    channel
      ..emit('PW_PID:1\nabc\x1b]P')
      ..emit('W;EXIT=7\x07')
      ..finish(0);
    await channel.closeOutput();
    expect(await _readAll(terminal), 'abc');
    expect(await terminal.exitCode, 7);
  });

  test(
    'a partial marker that never completes is shown as ordinary output',
    () async {
      final channel = _FakeChannel();
      final terminal = PtyHostTerminal(channel, markers: true);
      channel
        ..emit('PW_PID:1\nabc\x1b]PW')
        ..finish(-9);
      await channel.closeOutput();
      expect(await _readAll(terminal), 'abc\x1b]PW');
      expect(await terminal.exitCode, -9);
    },
  );

  test(
    'without the marker the channel exit code is used (killed by signal)',
    () async {
      final channel = _FakeChannel(knownPid: 77);
      final terminal = PtyHostTerminal(channel, markers: false);
      expect(await terminal.pid, 77);
      channel
        ..emit('partial')
        ..finish(-15);
      await channel.closeOutput();
      expect(await _readAll(terminal), 'partial');
      expect(await terminal.exitCode, -15);
    },
  );

  test('output is replayed to a subscriber that attaches later', () async {
    final channel = _FakeChannel();
    final terminal = PtyHostTerminal(channel, markers: true);
    channel
      ..emit('PW_PID:1\nfirst ')
      ..emit('second')
      ..finish(0);
    await channel.closeOutput();
    await Future<void>.delayed(Duration.zero);
    expect(await _readAll(terminal), 'first second');
  });

  test('input and resize are forwarded while the command runs', () async {
    final channel = _FakeChannel();
    PtyHostTerminal(channel, markers: false)
      ..write(Uint8List.fromList(utf8.encode('ls\r')))
      ..resize(90, 30);
    expect(channel.written.map(utf8.decode), ['ls\r']);
    expect(channel.resizes, [(90, 30)]);
  });

  test('input and resize are ignored after the command finished', () async {
    final channel = _FakeChannel();
    final terminal = PtyHostTerminal(channel, markers: false);
    channel.finish(0);
    await terminal.exitCode;
    terminal
      ..write(Uint8List.fromList(utf8.encode('late')))
      ..resize(10, 10);
    expect(channel.written, isEmpty);
    expect(channel.resizes, isEmpty);
  });

  test('execEventsOf emits pid, output and exit code in order', () async {
    final channel = _FakeChannel();
    final terminal = PtyHostTerminal(channel, markers: true);
    final events = execEventsOf(terminal).toList();
    channel
      ..emit('PW_PID:9\nhi\r\n\x1b]PW;EXIT=2\x07')
      ..finish(null);
    await channel.closeOutput();
    final list = await events;
    expect(list.first, isA<ExecStarted>());
    expect((list.first as ExecStarted).pid, 9);
    expect(
      list.whereType<ExecStdout>().map((e) => utf8.decode(e.bytes)).join(),
      'hi\r\n',
    );
    expect((list.last as ExecDone).exitCode, 2);
    expect((list.last as ExecDone).connectionLost, isFalse);
  });

  test(
    'execEventsOf reports a lost connection when the exit code errors',
    () async {
      final channel = _FakeChannel();
      final terminal = PtyHostTerminal(channel, markers: false);
      final events = execEventsOf(terminal).toList();
      unawaited(channel.closeOutput());
      channel._exit.completeError(const HostFailure('gone'));
      final list = await events;
      expect((list.last as ExecDone).connectionLost, isTrue);
    },
  );

  test('wrapTerminal prints the pid and exit markers and waits for the acknowledgement', () {
    final wrapped = ProcessControl(HostOs.posix).wrapTerminal('echo hi');
    expect(wrapped, contains('PW_PID:'));
    expect(wrapped, contains('PW;EXIT='));
    expect(wrapped, contains('read -r pw_ack'));
    expect(wrapped, contains('echo hi'));
  });
}
