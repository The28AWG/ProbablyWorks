// ignore_for_file: avoid-top-level-members-in-tests, avoid-substring
// Причина: инструмент импортируют тесты, а пути и хеши режутся по байтам ASCII.
/// Сверка апплета с настоящим git: код, вывод и состояние репозитория.
///
/// Оракул — git на машине, `LC_ALL=C`, пустой системный config и одни и те же
/// `GIT_AUTHOR_*`. Индекс сравнивается через `git ls-files -s`: поля stat
/// задаёт файловая система и в байты индекса не входят.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:virtual_git/virtual_git.dart';
import 'package:virtual_host/virtual_host.dart';

/// Команда, которую нельзя сверить побайтово, и причина из ограничений хоста.
final class GitParityWaiver {
  const GitParityWaiver(this.command, this.reason);

  final String command;
  final String reason;
}

/// Замороженное окружение сверки. Даты одинаковые, чтобы хеши совпали.
const gitParityEnvironment = {
  'GIT_AUTHOR_NAME': 'Ada',
  'GIT_AUTHOR_EMAIL': 'ada@ex.test',
  'GIT_COMMITTER_NAME': 'Ada',
  'GIT_COMMITTER_EMAIL': 'ada@ex.test',
  'GIT_AUTHOR_DATE': '1700000000 +0000',
  'GIT_COMMITTER_DATE': '1700000000 +0000',
  'LC_ALL': 'C',
  'GIT_CONFIG_NOSYSTEM': '1',
  'GIT_CONFIG_GLOBAL': '/dev/null',
  'GIT_CONFIG_COUNT': '0',
};

/// Два репозитория: каталог настоящего git и виртуальная ФС.
final class GitParitySession {
  GitParitySession({Map<String, String> environment = gitParityEnvironment})
    : environment = environment,
      _virtual = _ParityVirtual(environment);

  final Map<String, String> environment;
  final _ParityVirtual _virtual;
  late final Directory realRoot;

  Future<void> start() async {
    realRoot = await Directory.systemTemp.createTemp('git_parity_');
    template = await Directory.systemTemp.createTemp('git_parity_template_');
    await _virtual.ensure();
  }

  late final Directory template;

  Future<void> close() async {
    if (realRoot.existsSync()) await realRoot.delete(recursive: true);
    if (template.existsSync()) await template.delete(recursive: true);
  }

  Future<void> write(String path, String text) async {
    await _virtual.write(path, text);
    final file = File('${realRoot.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  /// Одна и та же команда на обеих сторонах. [waivers] пропускает сверку.
  ///
  /// `{root}` в аргументе — каталог этой стороны: `/work` у апплета и
  /// временный каталог у настоящего git. Так `clone {root} dst` клонирует
  /// свой источник, а пути в выводе после замены всё равно совпадают.
  Future<void> both(
    List<String> args, {
    List<GitParityWaiver> waivers = const [],
  }) async {
    final command = args.join(' ');
    GitParityWaiver? waiver;
    for (final item in waivers) {
      if (item.command == command) waiver = item;
    }
    final left = await _virtual.run(_rootArgs(args, '/work'));
    final right = await _real(_rootArgs(args, realRoot.path));
    if (waiver != null) {
      expect(waiver.reason, isNotEmpty, reason: command);
      return;
    }
    expect(
      left.code,
      right.exitCode,
      reason: '$command\nvirtual: ${left.err}\nreal: ${right.stderr}',
    );
    final realErr = '${right.stderr}'.replaceAll(realRoot.path, '/work');
    final realOut = '${right.stdout}'.replaceAll(realRoot.path, '/work');
    expect(left.err, realErr, reason: command);
    expect(left.out, realOut, reason: command);
  }

  Future<void> expectSameTree() async {
    final dumped = await Directory.systemTemp.createTemp('git_parity_vfs_');
    try {
      await _virtual.materialize('/work', dumped.path);
      final leftFiles = await _git(['-C', dumped.path, 'ls-files', '-s']);
      final rightFiles = await _git(['-C', realRoot.path, 'ls-files', '-s']);
      expect(leftFiles.stdout, rightFiles.stdout, reason: 'ls-files -s');
      final leftObjects = await _git([
        '-C',
        dumped.path,
        'rev-list',
        '--objects',
        '--all',
      ]);
      final rightObjects = await _git([
        '-C',
        realRoot.path,
        'rev-list',
        '--objects',
        '--all',
      ]);
      expect(
        leftObjects.stdout,
        rightObjects.stdout,
        reason: 'rev-list --objects --all',
      );
      await _compareWorkTree(dumped.path, realRoot.path);
    } finally {
      await dumped.delete(recursive: true);
    }
  }

  List<String> _rootArgs(List<String> args, String root) => [
    for (final arg in args) arg.replaceAll('{root}', root),
  ];

  Future<ProcessResult> _real(List<String> args) =>
      _git(['-C', realRoot.path, ...args]);

  Future<ProcessResult> _git(List<String> args) => Process.run(
    'git',
    args,
    environment: {...environment, 'GIT_TEMPLATE_DIR': template.path},
  );

  Future<void> _compareWorkTree(String left, String right) async {
    final leftFiles = await _files(left);
    final rightFiles = await _files(right);
    expect(leftFiles.keys.toList()..sort(), rightFiles.keys.toList()..sort());
    for (final path in leftFiles.keys) {
      if (path == '.git/index' || path.startsWith('.git/objects/pack/')) {
        continue;
      }
      expect(leftFiles[path], rightFiles[path], reason: path);
    }
  }

  Future<Map<String, List<int>>> _files(String root) async {
    final files = <String, List<int>>{};
    await for (final entity in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(root.length + 1);
      if (relative == '.git/index' ||
          relative.startsWith('.git/objects/pack/')) {
        continue;
      }
      files[relative] = await entity.readAsBytes();
    }
    return files;
  }
}

final class _ParityVirtual {
  _ParityVirtual(this.environment);

  final Map<String, String> environment;
  late final VirtualFs fs = VirtualFs(
    InMemoryVfsStore(),
    snapshot: OsSnapshot(
      profile: VirtualProfile(home: '/work', environment: environment),
      names: {...standardApplets.names, 'git'},
    ),
  );
  var ready = false;

  Future<void> ensure() async {
    if (ready) return;
    await fs.mkdir('/work', recursive: true);
    ready = true;
  }

  Future<void> write(String path, String text) async {
    await ensure();
    final absolute = '/work/$path';
    final parent = absolute.substring(0, absolute.lastIndexOf('/'));
    if (parent.isNotEmpty) await fs.mkdir(parent, recursive: true);
    await fs.writeBytes(absolute, Uint8List.fromList(utf8.encode(text)));
  }

  Future<({int code, String out, String err})> run(List<String> args) async {
    await ensure();
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
        .run('git ${args.join(' ')}', cwd: '/work')
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

  Future<void> materialize(String root, String destination) async {
    final nodes = await fs.walk(root);
    for (final node in nodes) {
      final relative = node.path.substring(root.length);
      final target = '$destination$relative';
      if (node.kind == VfsNodeKind.dir) {
        await Directory(target).create(recursive: true);
        continue;
      }
      await Directory(target).parent.create(recursive: true);
      if (node.kind == VfsNodeKind.symlink) {
        await Link(target).create(node.target ?? '');
        continue;
      }
      await File(target).writeAsBytes(await fs.readBytes(node.path));
    }
  }
}
