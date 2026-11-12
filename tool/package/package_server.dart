import 'dart:io';

import 'package:path/path.dart' as p;

/// Собирает standalone-пакеты headless-сервера.
///
/// Linux/macOS: tar.gz и (только Linux) DEB. Windows: zip. Внутри архива
/// лежит `probably-works-server/bin`, `lib` и README; нативные библиотеки
/// должны оставаться рядом, иначе загрузчик Dart их не найдёт.
Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }
  final options = _Options.parse(arguments);
  if (options.error != null) {
    stderr
      ..writeln(options.error)
      ..writeln()
      ..writeln(_usage);
    exitCode = 2;
    return;
  }

  final projectRoot = Directory.current;
  final version = _readVersion(projectRoot);
  if (version == null) {
    stderr.writeln('package_server: version not found in pubspec.yaml');
    exitCode = 2;
    return;
  }
  final output = Directory(p.join(projectRoot.path, 'dist', version))
    ..createSync(recursive: true);
  final temp = Directory.systemTemp.createTempSync('pw_server_package_');
  try {
    final build = Directory(p.join(temp.path, 'build'));
    final target = p.join(
      projectRoot.path,
      'packages',
      'pw_server',
      'bin',
      'pw_server.dart',
    );
    final result = await Process.run(Platform.resolvedExecutable, [
      'build',
      'cli',
      '--target',
      target,
      '-o',
      build.path,
    ], workingDirectory: projectRoot.path);
    if (result.exitCode != 0) {
      stderr
        ..writeln('package_server: dart build cli failed')
        ..write(result.stdout)
        ..write(result.stderr);
      exitCode = result.exitCode;
      return;
    }

    final bundle = Directory(p.join(build.path, 'bundle'));
    final staging = Directory(p.join(temp.path, 'staging'));
    final app = Directory(p.join(staging.path, 'probably-works-server'))
      ..createSync(recursive: true);
    _copyDirectory(Directory(p.join(bundle.path, 'bin')), app, 'bin');
    _copyDirectory(Directory(p.join(bundle.path, 'lib')), app, 'lib');
    File(p.join(projectRoot.path, 'tool', 'server', 'README.md'))
        .copySync(p.join(app.path, 'README.md'));

    final base =
        'probably-works-server-$version-${options.platform}-${options.arch}';
    if (options.platform == 'windows') {
      await _zip(staging, File(p.join(output.path, '$base.zip')));
    } else {
      await _tarGz(staging, File(p.join(output.path, '$base.tar.gz')));
    }
    if (options.platform == 'linux') {
      await _deb(
        staging,
        output,
        version: version,
        arch: options.arch,
        projectRoot: projectRoot,
      );
    }
    stdout.writeln('Server packages written to ${output.path}');
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('package_server: $error')
      ..writeln(stackTrace);
    exitCode = 1;
  } finally {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

const _usage = '''
Использование: dart run tool/package/package_server.dart
               [--platform=linux|macos|windows] [--arch=x64|arm64]

По умолчанию собирается текущая ОС и x64.
Артефакты кладутся в dist/<version>/.
''';

final class _Options {
  const _Options({required this.platform, required this.arch, this.error});

  factory _Options.parse(List<String> arguments) {
    var platform = _hostPlatform();
    var arch = 'x64';
    for (final argument in arguments) {
      if (argument.startsWith('--platform=')) {
        platform = argument.replaceFirst('--platform=', '');
      } else if (argument.startsWith('--arch=')) {
        arch = argument.replaceFirst('--arch=', '');
      } else {
        return _Options(
          platform: platform,
          arch: arch,
          error: 'Неизвестный аргумент: $argument',
        );
      }
    }
    if (!const {'linux', 'macos', 'windows'}.contains(platform)) {
      return _Options(
        platform: platform,
        arch: arch,
        error: 'Неизвестная платформа: $platform',
      );
    }
    if (!const {'x64', 'arm64'}.contains(arch)) {
      return _Options(
        platform: platform,
        arch: arch,
        error: 'Неизвестная архитектура: $arch',
      );
    }
    return _Options(platform: platform, arch: arch);
  }

  final String platform;
  final String arch;
  final String? error;
}

String _hostPlatform() {
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  throw UnsupportedError('Unsupported desktop platform');
}

String? _readVersion(Directory root) {
  final pubspec = File(p.join(root.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return null;
  final match = RegExp(
    r'^version:\s*(.+)$',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync());
  return match?.group(1)?.trim();
}

void _copyDirectory(Directory source, Directory destination, String name) {
  if (!source.existsSync()) {
    throw StateError('${source.path} is missing');
  }
  final target = Directory(p.join(destination.path, name));
  for (final entity in source.listSync(recursive: true)) {
    final relative = p.relative(entity.path, from: source.path);
    final path = p.join(target.path, relative);
    if (entity is Directory) {
      Directory(path).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(path)).createSync(recursive: true);
      entity.copySync(path);
    }
  }
  if (!Platform.isWindows) {
    final executable = File(p.join(target.path, 'pw_server'));
    if (executable.existsSync()) {
      Process.runSync('chmod', ['755', executable.path]);
    }
  }
}

Future<void> _tarGz(Directory staging, File output) async {
  final result = await Process.run('tar', [
    '-czf',
    output.path,
    '-C',
    staging.path,
    'probably-works-server',
  ]);
  if (result.exitCode != 0) {
    throw StateError('tar failed: ${result.stderr}');
  }
}

Future<void> _zip(Directory staging, File output) async {
  if (output.existsSync()) output.deleteSync();
  final archivePath = p.join(staging.path, 'probably-works-server');
  final escapedArchive = archivePath.replaceAll("'", "''");
  final escapedOutput = output.path.replaceAll("'", "''");
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "Compress-Archive -Path '$escapedArchive' -DestinationPath '$escapedOutput' -Force",
  ]);
  if (result.exitCode != 0) {
    throw StateError('Compress-Archive failed: ${result.stderr}');
  }
}

Future<void> _deb(
  Directory staging,
  Directory output, {
  required String version,
  required String arch,
  required Directory projectRoot,
}) async {
  final root = Directory(p.join(staging.path, 'deb'))..createSync();
  final app = Directory(p.join(root.path, 'opt', 'probably-works-server'));
  _copyDirectory(
    Directory(p.join(staging.path, 'probably-works-server', 'bin')),
    app,
    'bin',
  );
  _copyDirectory(
    Directory(p.join(staging.path, 'probably-works-server', 'lib')),
    app,
    'lib',
  );

  final bin = Directory(p.join(root.path, 'usr', 'bin'))
    ..createSync(recursive: true);
  final wrapper = File(p.join(bin.path, 'pw-server'))
    ..writeAsStringSync(
      '#!/bin/sh\nexec /opt/probably-works-server/bin/pw_server "\$@"\n',
    );
  Process.runSync('chmod', ['755', wrapper.path]);

  final doc = Directory(
    p.join(root.path, 'usr', 'share', 'doc', 'probably-works-server'),
  )..createSync(recursive: true);
  File(p.join(projectRoot.path, 'tool', 'server', 'README.md'))
      .copySync(p.join(doc.path, 'README.md'));

  final control = Directory(p.join(root.path, 'DEBIAN'))
    ..createSync(recursive: true);
  File(p.join(control.path, 'control')).writeAsStringSync('''
Package: probably-works-server
Version: $version
Section: utils
Priority: optional
Architecture: ${arch == 'arm64' ? 'arm64' : 'amd64'}
Maintainer: Ruslan Gabdrafikov <the28awg@gmail.com>
Homepage: https://github.com/The28AWG/ProbablyWorks
Depends: libc6
Description: Headless ProbablyWorks agent server
 SQLite, HTTP API, scheduler and command execution without the GUI.
''');

  final deb = File(
    p.join(
      output.path,
      'probably-works-server_${version}_${arch == 'arm64' ? 'arm64' : 'amd64'}.deb',
    ),
  );
  final result = await Process.run('dpkg-deb', [
    '--build',
    '--root-owner-group',
    root.path,
    deb.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('dpkg-deb failed: ${result.stderr}');
  }
}
