import 'dart:io';

import 'package:path/path.dart' as p;

import 'package_archive.dart';

/// Собирает готовый архив статического web-клиента.
///
/// В отличие от `package_server_web.dart` здесь нет сервера и URL rewrite:
/// сборка использует `lib/main_web.dart` с hash-навигацией и подходит для
/// любого статического хостинга.
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
  final version = readVersion(projectRoot);
  if (version == null) {
    stderr.writeln('package_web: version not found in pubspec.yaml');
    exitCode = 2;
    return;
  }
  final output = Directory(p.join(projectRoot.path, 'dist', version))
    ..createSync(recursive: true);
  final temp = Directory.systemTemp.createTempSync('pw_web_package_');
  try {
    final web = options.webDir == null
        ? Directory(p.join(temp.path, 'web'))
        : Directory(options.webDir!);
    if (options.webDir == null) {
      await buildWeb(
        projectRoot,
        'lib/main_web.dart',
        web,
        baseHref: options.baseHref,
      );
    }
    if (!File(p.join(web.path, 'index.html')).existsSync()) {
      stderr.writeln('package_web: ${web.path} has no index.html');
      exitCode = 2;
      return;
    }

    final staging = Directory(p.join(temp.path, 'staging'));
    copyDirectory(web, staging, 'probably-works-web');
    File(p.join(projectRoot.path, 'tool', 'web', 'README.md'))
        .copySync(p.join(staging.path, 'probably-works-web', 'README.md'));
    File(p.join(projectRoot.path, 'LICENSE'))
        .copySync(p.join(staging.path, 'probably-works-web', 'LICENSE'));

    final base = 'probably-works-web-$version';
    if (Platform.isWindows) {
      await zip(
        staging,
        File(p.join(output.path, '$base.zip')),
        'probably-works-web',
      );
    } else {
      await tarGz(
        staging,
        File(p.join(output.path, '$base.tar.gz')),
        'probably-works-web',
      );
    }
    stdout.writeln('Web package written to ${output.path}');
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('package_web: $error')
      ..writeln(stackTrace);
    exitCode = 1;
  } finally {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

const _usage = '''
Использование: dart run tool/package/package_web.dart
               [--web-dir=<path>] [--base-href=/]

Без --web-dir скрипт сам собирает lib/main_web.dart.
Артефакт кладётся в dist/<version>/.
''';

final class _Options {
  const _Options({this.webDir, this.baseHref = '/', this.error});

  factory _Options.parse(List<String> arguments) {
    String? webDir;
    var baseHref = '/';
    for (final argument in arguments) {
      if (argument.startsWith('--web-dir=')) {
        webDir = argument.replaceFirst('--web-dir=', '');
      } else if (argument.startsWith('--base-href=')) {
        baseHref = argument.replaceFirst('--base-href=', '');
      } else {
        return _Options(
          webDir: webDir,
          baseHref: baseHref,
          error: 'Неизвестный аргумент: $argument',
        );
      }
    }
    if (!baseHref.startsWith('/') || !baseHref.endsWith('/')) {
      return _Options(
        webDir: webDir,
        baseHref: baseHref,
        error: '--base-href должен начинаться и заканчиваться на /',
      );
    }
    return _Options(webDir: webDir, baseHref: baseHref);
  }

  final String? webDir;
  final String baseHref;
  final String? error;
}
