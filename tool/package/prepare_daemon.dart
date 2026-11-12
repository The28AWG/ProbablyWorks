import 'dart:io';

import 'package:path/path.dart' as p;

/// Кладёт AOT-сборку демона в готовый bundle приложения.
///
/// Fastforge вызывает этот скрипт как pre-hook после `flutter build` и до
/// упаковки. `dart build cli` нужен вместо `dart compile exe`: у `sqlite3` и
/// `portable_pty` есть build hooks, а `dart compile` их не поддерживает.
///
/// Результат сохраняет раскладку `daemon/bin` + `daemon/lib`: загрузчик
/// нативных ассетов ищет библиотеки относительно `../lib` от бинарника.
Future<void> main() async {
  final platform = Platform.environment['PLATFORM'];
  final buildOutput = Platform.environment['BUILD_OUTPUT_DIRECTORY'];
  if (platform == null || platform.isEmpty) {
    stderr.writeln('prepare_daemon: PLATFORM is not set');
    exitCode = 2;
    return;
  }
  if (buildOutput == null || buildOutput.isEmpty) {
    stderr.writeln('prepare_daemon: BUILD_OUTPUT_DIRECTORY is not set');
    exitCode = 2;
    return;
  }

  final projectRoot = Directory.current;
  final target = p.join(
    projectRoot.path,
    'packages',
    'pw_server',
    'bin',
    'pw_server.dart',
  );
  if (!File(target).existsSync()) {
    stderr.writeln('prepare_daemon: $target not found');
    exitCode = 2;
    return;
  }

  final buildDirectory = Directory(buildOutput);
  final destination = _destination(platform, buildDirectory);
  final temp = Directory.systemTemp.createTempSync('probably_works_daemon_');
  try {
    stdout.writeln('Building daemon for $platform...');
    final result = await Process.run(Platform.resolvedExecutable, [
      'build',
      'cli',
      '--target',
      target,
      '-o',
      temp.path,
    ], workingDirectory: projectRoot.path);
    if (result.exitCode != 0) {
      stderr
        ..writeln('prepare_daemon: dart build cli failed')
        ..write(result.stdout)
        ..write(result.stderr);
      exitCode = result.exitCode;
      return;
    }
    if (Platform.environment['PROBABLY_WORKS_PACKAGE_VERBOSE'] == '1') {
      stdout
        ..write(result.stdout)
        ..write(result.stderr);
    }

    final bundle = Directory(p.join(temp.path, 'bundle'));
    if (!bundle.existsSync()) {
      stderr.writeln('prepare_daemon: ${bundle.path} was not created');
      exitCode = 1;
      return;
    }
    _copyBundle(bundle, destination);
    if (Platform.isMacOS) await _signMacos(buildDirectory);
    stdout.writeln('Daemon bundled at ${destination.path}');
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('prepare_daemon: $error')
      ..writeln(stackTrace);
    exitCode = 1;
  } finally {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

/// Каталог `daemon` внутри bundle GUI или `.app` на macOS.
Directory _destination(String platform, Directory buildOutput) {
  if (platform != 'macos') {
    return Directory(p.join(buildOutput.path, 'daemon'));
  }
  final apps = buildOutput
      .listSync()
      .whereType<Directory>()
      .where((entity) => entity.path.endsWith('.app'))
      .toList();
  if (apps.length != 1) {
    throw StateError(
      'Expected one .app in ${buildOutput.path}, found ${apps.length}',
    );
  }
  return Directory(p.join(apps.single.path, 'Contents', 'MacOS', 'daemon'));
}

/// Копирует `bundle/bin` и `bundle/lib`, сохраняя относительные пути.
void _copyBundle(Directory source, Directory destination) {
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  for (final name in ['bin', 'lib']) {
    final from = Directory(p.join(source.path, name));
    if (!from.existsSync()) {
      throw StateError('${from.path} is missing in the daemon build');
    }
    final to = Directory(p.join(destination.path, name))
      ..createSync(recursive: true);
    for (final entity in from.listSync(recursive: true)) {
      final relative = p.relative(entity.path, from: from.path);
      final target = p.join(to.path, relative);
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        Directory(p.dirname(target)).createSync(recursive: true);
        entity.copySync(target);
      }
    }
  }
  if (!Platform.isWindows) {
    final executable = File(p.join(destination.path, 'bin', 'pw_server'));
    if (!executable.existsSync()) {
      throw StateError('${executable.path} is missing after copy');
    }
    final chmod = Process.runSync('chmod', ['755', executable.path]);
    if (chmod.exitCode != 0) {
      throw StateError('chmod failed: ${chmod.stderr}');
    }
  }
}

/// Переподписывает `.app`: добавленный после Xcode бинарник ломает подпись.
///
/// Без `PROBABLY_WORKS_CODESIGN_IDENTITY` используется ad-hoc подпись — она
/// годится для локальной установки, но не для распространения.
Future<void> _signMacos(Directory buildOutput) async {
  final apps = buildOutput
      .listSync()
      .whereType<Directory>()
      .where((entity) => entity.path.endsWith('.app'))
      .toList();
  if (apps.length != 1) return;
  final identity =
      Platform.environment['PROBABLY_WORKS_CODESIGN_IDENTITY'] ?? '-';
  final result = await Process.run('codesign', [
    '--force',
    '--deep',
    '--sign',
    identity,
    apps.single.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('codesign failed: ${result.stderr}');
  }
  stdout.writeln('Signed ${apps.single.path} with $identity');
}
