import 'dart:io';

import 'package:path/path.dart' as p;

/// Общие операции упаковки серверных и web-артефактов.
///
/// Скрипты в `tool/package` запускаются из корня репозитория и используют
/// системные `tar`/PowerShell, чтобы не добавлять `archive` в зависимости
/// приложения.

/// Читает `version` из корневого `pubspec.yaml`.
String? readVersion(Directory root) {
  final pubspec = File(p.join(root.path, 'pubspec.yaml'));
  if (!pubspec.existsSync()) return null;
  final match = RegExp(
    r'^version:\s*(.+)$',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync());
  return match?.group(1)?.trim();
}

/// Текущая desktop-платформа в именах release-артефактов.
String hostPlatform() {
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  throw UnsupportedError('Unsupported desktop platform');
}

/// Копирует каталог `source` в `destination/name`, сохраняя структуру.
void copyDirectory(Directory source, Directory destination, String name) {
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
}

/// Выставляет executable-бит на Unix. На Windows ничего не делает.
void ensureExecutable(String path) {
  if (Platform.isWindows) return;
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('$path is missing');
  }
  final result = Process.runSync('chmod', ['755', path]);
  if (result.exitCode != 0) {
    throw StateError('chmod failed: ${result.stderr}');
  }
}

/// Собирает Flutter web в указанный каталог.
///
/// Всегда включает `--wasm`: браузеры с WasmGC исполняют WebAssembly, а
/// остальные получают JS-fallback, который Flutter кладёт в ту же сборку.
/// Так релиз не теряет поддержку старых браузеров.
Future<void> buildWeb(
  Directory projectRoot,
  String entrypoint,
  Directory output, {
  String baseHref = '/',
}) async {
  final result = await Process.run(
    'flutter',
    [
      'build',
      'web',
      '-t',
      entrypoint,
      '--wasm',
      '--release',
      '-o',
      output.path,
      '--base-href=$baseHref',
    ],
    workingDirectory: projectRoot.path,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'flutter build web failed\n${result.stdout}${result.stderr}',
    );
  }
}

/// Создаёт `tar.gz` из каталога `staging` с корнем `archiveName`.
Future<void> tarGz(Directory staging, File output, String archiveName) async {
  final result = await Process.run('tar', [
    '-czf',
    output.path,
    '-C',
    staging.path,
    archiveName,
  ]);
  if (result.exitCode != 0) {
    throw StateError('tar failed: ${result.stderr}');
  }
}

/// Создаёт zip через PowerShell. Используется на Windows.
Future<void> zip(Directory staging, File output, String archiveName) async {
  if (output.existsSync()) output.deleteSync();
  final archivePath = p.join(staging.path, archiveName);
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
