import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:virtual_git/virtual_git.dart';
import 'package:virtual_host/virtual_host.dart';

import 'support/git_parity.dart';

void main() {
  const env = gitParityEnvironment;

  gitParityTest('ошибки разбора совпадают с git', () async {
    final realRoot = await Directory.systemTemp.createTemp('git_cli_err_');
    addTearDown(() => realRoot.delete(recursive: true));

    Future<({int code, String err})> real(List<String> args) async {
      final result = await Process.run(
        'git',
        ['-C', realRoot.path, ...args],
        environment: {
          ...env,
          'HOME': realRoot.path,
          'PATH':
              Platform.environment['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
        },
        includeParentEnvironment: false,
      );
      return (code: result.exitCode, err: result.stderr as String);
    }

    final virtual = _Virtual(env);
    for (final args in [
      ['clone', '--depth'],
      ['clone', '--nope'],
      ['-C'],
    ]) {
      final left = await virtual.run(args);
      final right = await real(args);
      expect(left.code, right.code, reason: args.join(' '));
      expect(
        left.err.split('\n').first,
        right.err.split('\n').first,
        reason: args.join(' '),
      );
    }

    final missing = await virtual.run(['clone', '--depth', '0', '/tmp/nope']);
    expect(missing.code, 128);
    expect(missing.err, 'fatal: depth 0 is not a positive number\n');

    final outside = await virtual.run(['commit', '-m']);
    final outsideReal = await real(['commit', '-m']);
    expect(outside.code, outsideReal.code);
    expect(outside.err, contains('not a git repository'));
    expect(outsideReal.err, contains('not a git repository'));
  });

  gitParityTest('локальная история совпадает с git', () async {
    final realRoot = await Directory.systemTemp.createTemp('git_cli_parity_');
    addTearDown(() => realRoot.delete(recursive: true));
    final virtual = _Virtual(env);

    Future<({int code, String out, String err})> real(List<String> args) async {
      final result = await Process.run(
        'git',
        ['-C', realRoot.path, ...args],
        environment: {
          ...env,
          'HOME': realRoot.path,
          'PATH':
              Platform.environment['PATH'] ?? '/usr/local/bin:/usr/bin:/bin',
        },
        includeParentEnvironment: false,
      );
      return (
        code: result.exitCode,
        out: result.stdout as String,
        err: result.stderr as String,
      );
    }

    Future<void> both(List<String> args) async {
      final left = await virtual.run(args);
      final right = await real(args);
      expect(left.code, right.code, reason: '${args.join(' ')}\n${left.err}');
      expect(left.err, right.err, reason: args.join(' '));
      expect(left.out, right.out, reason: args.join(' '));
    }

    await virtual.run(['init', '-b', 'main']);
    await real(['init', '-b', 'main']);
    await virtual.write('a.txt', 'a\n');
    await File('${realRoot.path}/a.txt').writeAsString('a\n');
    await both(['add', 'a.txt']);
    await both(['commit', '-m']);
    await both(['commit', '-m', 'first']);
    await both(['rev-parse', 'HEAD']);
    await both(['ls-files', '-s']);
    await both(['status', '--porcelain=v1']);
    await both(['log', '--oneline']);

    await virtual.write('a.txt', 'a\nb\n');
    await File('${realRoot.path}/a.txt').writeAsString('a\nb\n');
    await both(['diff']);
    await both(['status', '--porcelain']);
    await both(['commit', '-am', 'second']);
    await both(['rev-parse', 'HEAD']);
    await both(['log', '--oneline', '-2']);
    await both(['branch', 'topic']);
    await both(['branch']);
    await both(['checkout', '-b', 'other']);
    await both(['switch', 'main']);
    await both(['rev-parse', '--abbrev-ref', 'HEAD']);
    await both(['rev-parse', '--short=7', 'HEAD']);
    await both(['tag', 'v1']);
    await both(['tag']);
    await both(['branch', '-d', 'other']);
    await both(['branch', '--show-current']);
    await both(['show', '--oneline', 'HEAD']);
    await both(['log', '-1', '--oneline']);

    await virtual.write('a.txt', 'a\nb\nc\n');
    await File('${realRoot.path}/a.txt').writeAsString('a\nb\nc\n');
    await both(['add', 'a.txt']);
    await both(['diff', '--cached']);
    await both(['restore', '--staged', 'a.txt']);
    await both(['status', '--porcelain']);
    await both(['checkout', '--', 'a.txt']);
    await both(['status', '--porcelain']);

    await both(['branch', 'side']);
    await both(['switch', 'side']);
    await virtual.write('a.txt', 'side\n');
    await File('${realRoot.path}/a.txt').writeAsString('side\n');
    await both(['commit', '-am', 'side']);
    await both(['switch', 'main']);
    await both(['merge', 'side']);
    await both(['rev-parse', 'HEAD']);

    await virtual.write('a.txt', 'stashed\n');
    await File('${realRoot.path}/a.txt').writeAsString('stashed\n');
    await both(['status']);
    await both(['stash', 'push', '-m', 'wip']);
    await both(['stash', 'list']);
    await both(['status', '--porcelain']);
    await both(['stash', 'pop']);
    await both(['diff']);

    await both(['remote', 'add', 'origin', '/tmp/origin.git']);
    await both(['remote', '-v']);
    await both(['remote', 'get-url', 'origin']);
    await both(['remote', 'remove', 'origin']);
    await both(['remote']);
  });
}

final class _Virtual {
  _Virtual(this.environment);

  final Map<String, String> environment;
  late final VirtualFs fs = VirtualFs(
    InMemoryVfsStore(),
    snapshot: OsSnapshot(
      profile: VirtualProfile(home: '/work', environment: environment),
      names: {...standardApplets.names, 'git'},
    ),
  );
  var _ready = false;

  Future<void> write(String path, String text) async {
    await _ensure();
    await fs.writeBytes('/work/$path', Uint8List.fromList(utf8.encode(text)));
  }

  Future<({int code, String out, String err})> run(List<String> args) async {
    await _ensure();
    final applets = AppletRegistry([
      for (final name in standardApplets.names) standardApplets.lookup(name)!,
      const GitApplet(),
    ]);
    final interpreter = ShellInterpreter(
      fs: fs,
      applets: applets,
      profile: VirtualProfile(home: '/work', environment: environment),
    );
    final events = await interpreter
        .run('git ${_quote(args)}', cwd: '/work')
        .toList();
    final stdout = BytesBuilder();
    final stderr = BytesBuilder();
    var code = -1;
    for (final event in events) {
      switch (event) {
        case ShellStdout(:final bytes):
          stdout.add(bytes);
        case ShellStderr(:final bytes):
          stderr.add(bytes);
        case ShellDone(:final exitCode):
          code = exitCode ?? -1;
      }
    }
    return (
      code: code,
      out: utf8.decode(stdout.toBytes()),
      err: utf8.decode(stderr.toBytes()),
    );
  }

  Future<void> _ensure() async {
    if (_ready) return;
    await fs.mkdir('/work', recursive: true);
    _ready = true;
  }
}

/// Собирает argv в одну строку оболочки. Кавычки нужны, потому что интерпретатор
/// режет слова сам: значение опции с пробелом не встречается в этих тестах.
String _quote(List<String> args) => args.join(' ');
