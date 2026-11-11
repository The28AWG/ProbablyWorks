import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/host/host_op.dart';
import 'package:pw_agent/host/host_runtime.dart';
import 'package:pw_agent/host/virtual/virtual_host_runtime.dart';
import 'package:virtual_host/virtual_host.dart';

const _profile = VirtualProfile(hostname: 'sandbox');

/// Рантайм поверх свежей ФС с домашним каталогом: как после создания виртуального Host.
Future<VirtualHostRuntime> _runtime() async {
  final fs = VirtualFs(InMemoryVfsStore(), clock: () => 1700000000);
  await seedVirtualHost(fs, _profile);
  return VirtualHostRuntime(
    fs: fs,
    profile: _profile,
    applets: standardApplets,
  );
}

String _stdout(List<ExecEvent> events) => utf8.decode([
  for (final e in events)
    if (e is ExecStdout) ...e.bytes,
]);

String _stderr(List<ExecEvent> events) => utf8.decode([
  for (final e in events)
    if (e is ExecStderr) ...e.bytes,
]);

ExecDone _done(List<ExecEvent> events) => events.last as ExecDone;

void main() {
  test('виртуальный Host не имеет терминала и сообщает posix', () async {
    final runtime = await _runtime();

    expect(runtime.hasTerminal, isFalse);
    expect(runtime.os, HostOs.posix);
  });

  test('openTerminal бросает HostFailure: терминала нет', () async {
    final runtime = await _runtime();

    expect(() => runtime.openTerminal('sh'), throwsA(isA<HostFailure>()));
  });

  test('run выполняет команду в VFS: запись и чтение файла', () async {
    final runtime = await _runtime();

    final events = await runtime
        .run('echo hello > note.txt && cat note.txt')
        .toList();

    expect(_stdout(events), 'hello\n');
    expect(_done(events).exitCode, 0);
  });

  test('run раскрывает cwd с тильдой в домашний каталог', () async {
    final runtime = await _runtime();

    final events = await runtime.run('pwd', cwd: '~').toList();

    expect(_stdout(events), '/home/agent\n');
  });

  test('run раскрывает cwd вида ~/каталог относительно дома', () async {
    final runtime = await _runtime();
    await runtime.run('mkdir -p projects').drain<void>();

    final events = await runtime.run('pwd', cwd: '~/projects').toList();

    expect(_stdout(events), '/home/agent/projects\n');
  });

  test('run передаёт stdin процессу', () async {
    final runtime = await _runtime();

    final events = await runtime
        .run('cat', stdin: Uint8List.fromList(utf8.encode('из файла')))
        .toList();

    expect(_stdout(events), 'из файла');
  });

  test('run: неизвестная команда завершается кодом 127', () async {
    final runtime = await _runtime();

    final events = await runtime.run('no-such-command').toList();

    expect(_done(events).exitCode, 127);
  });

  test('perform отдаёт вывод операции и завершается ExecDone', () async {
    final runtime = await _runtime();
    await runtime.run('echo one > a.txt').drain<void>();

    final events = await runtime
        .perform(const ListDirOp('/home/agent'))
        .toList();

    expect(_stdout(events), contains('a.txt'));
    expect(events.last, isA<ExecDone>());
    expect(_done(events).exitCode, 0);
  });

  test(
    'perform с ошибкой ФС даёт stderr и ненулевой код, без исключения',
    () async {
      final runtime = await _runtime();

      final events = await runtime
          .perform(const ListDirOp('/missing'))
          .toList();

      expect(_stderr(events), isNotEmpty);
      expect(_done(events).exitCode, isNot(0));
    },
  );

  test(
    'ни run, ни perform не выдают ExecStarted: pid у виртуального нет',
    () async {
      final runtime = await _runtime();

      final viaRun = await runtime.run('echo x').toList();
      final viaPerform = await runtime.perform(const HostInfoOp()).toList();

      expect(viaRun.whereType<ExecStarted>(), isEmpty);
      expect(viaPerform.whereType<ExecStarted>(), isEmpty);
    },
  );

  test('канонический путь раскрывает тильду и симлинк, хвост может отсутствовать', () async {
    final runtime = await _runtime();
    await runtime
        .run(
          'mkdir -p real && echo x > real/a.txt && ln -s /home/agent/real link',
        )
        .drain<void>();

    final viaHome = await runtime
        .perform(const CanonicalPathOp('~/link/a.txt'))
        .toList();
    expect(_done(viaHome).exitCode, 0);
    expect(_stdout(viaHome).trim(), '/home/agent/real/a.txt');

    final missing = await runtime
        .perform(const CanonicalPathOp('~/link/new/file.txt'))
        .toList();
    expect(_stdout(missing).trim(), '/home/agent/real/new/file.txt');
  });

  test('host_info называет профиль и доступные апплеты', () async {
    final runtime = await _runtime();

    final events = await runtime.perform(const HostInfoOp()).toList();
    final info = _stdout(events);

    expect(info, contains('Linux sandbox'));
    expect(info, contains('user=agent'));
    expect(info, contains('applets='));
    expect(info, contains('cat'));
    expect(info, contains('ls /bin lists commands'));
  });
}
