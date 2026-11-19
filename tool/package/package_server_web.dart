import 'dart:io';

import 'package:path/path.dart' as p;

import 'package_archive.dart';

/// Собирает дистрибутив «сервер + web».
///
/// Внутри архива сервер и статика лежат отдельно: `server/` и `web/`.
/// Серверный процесс запускает пользователь, web-клиент его не поднимает.
/// Launcher только передаёт серверу `--web-dir web`.
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
    stderr.writeln('package_server_web: version not found in pubspec.yaml');
    exitCode = 2;
    return;
  }
  final output = Directory(p.join(projectRoot.path, 'dist', version))
    ..createSync(recursive: true);
  final temp = Directory.systemTemp.createTempSync('pw_server_web_package_');
  try {
    final web = options.webDir == null
        ? Directory(p.join(temp.path, 'web'))
        : Directory(options.webDir!);
    if (options.webDir == null) {
      await buildWeb(
        projectRoot,
        'lib/main_web_hosted.dart',
        web,
        baseHref: options.baseHref,
      );
    }
    if (!File(p.join(web.path, 'index.html')).existsSync()) {
      stderr.writeln('package_server_web: ${web.path} has no index.html');
      exitCode = 2;
      return;
    }

    final build = Directory(p.join(temp.path, 'server-build'));
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
        ..writeln('package_server_web: dart build cli failed')
        ..write(result.stdout)
        ..write(result.stderr);
      exitCode = result.exitCode;
      return;
    }

    final bundle = Directory(p.join(build.path, 'bundle'));
    final staging = Directory(p.join(temp.path, 'staging'));
    final app = Directory(p.join(staging.path, 'probably-works-server-web'))
      ..createSync(recursive: true);
    final server = Directory(p.join(app.path, 'server'))..createSync();
    copyDirectory(Directory(p.join(bundle.path, 'bin')), server, 'bin');
    copyDirectory(Directory(p.join(bundle.path, 'lib')), server, 'lib');
    ensureExecutable(p.join(server.path, 'bin', 'pw_server'));
    copyDirectory(web, app, 'web');

    for (final name in ['start.sh', 'start.bat', 'README.md']) {
      File(p.join(projectRoot.path, 'tool', 'server-web', name))
          .copySync(p.join(app.path, name));
    }
    ensureExecutable(p.join(app.path, 'start.sh'));
    File(p.join(projectRoot.path, 'LICENSE'))
        .copySync(p.join(app.path, 'LICENSE'));

    final base =
        'probably-works-server-web-$version-${options.platform}-${options.arch}';
    if (options.platform == 'windows') {
      await zip(
        staging,
        File(p.join(output.path, '$base.zip')),
        'probably-works-server-web',
      );
    } else {
      await tarGz(
        staging,
        File(p.join(output.path, '$base.tar.gz')),
        'probably-works-server-web',
      );
    }
    stdout.writeln('Server + web package written to ${output.path}');
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('package_server_web: $error')
      ..writeln(stackTrace);
    exitCode = 1;
  } finally {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  }
}

const _usage = '''
Использование: dart run tool/package/package_server_web.dart
               [--platform=linux|macos|windows] [--arch=x64|arm64]
               [--web-dir=<path>] [--base-href=/]

Без --web-dir скрипт сам собирает lib/main_web_hosted.dart.
Артефакт кладётся в dist/<version>/.
''';

final class _Options {
  const _Options({
    required this.platform,
    required this.arch,
    this.webDir,
    this.baseHref = '/',
    this.error,
  });

  factory _Options.parse(List<String> arguments) {
    var platform = hostPlatform();
    var arch = 'x64';
    String? webDir;
    var baseHref = '/';
    for (final argument in arguments) {
      if (argument.startsWith('--platform=')) {
        platform = argument.replaceFirst('--platform=', '');
      } else if (argument.startsWith('--arch=')) {
        arch = argument.replaceFirst('--arch=', '');
      } else if (argument.startsWith('--web-dir=')) {
        webDir = argument.replaceFirst('--web-dir=', '');
      } else if (argument.startsWith('--base-href=')) {
        baseHref = argument.replaceFirst('--base-href=', '');
      } else {
        return _Options(
          platform: platform,
          arch: arch,
          webDir: webDir,
          baseHref: baseHref,
          error: 'Неизвестный аргумент: $argument',
        );
      }
    }
    if (!const {'linux', 'macos', 'windows'}.contains(platform)) {
      return _Options(
        platform: platform,
        arch: arch,
        webDir: webDir,
        baseHref: baseHref,
        error: 'Неизвестная платформа: $platform',
      );
    }
    if (!const {'x64', 'arm64'}.contains(arch)) {
      return _Options(
        platform: platform,
        arch: arch,
        webDir: webDir,
        baseHref: baseHref,
        error: 'Неизвестная архитектура: $arch',
      );
    }
    if (!baseHref.startsWith('/') || !baseHref.endsWith('/')) {
      return _Options(
        platform: platform,
        arch: arch,
        webDir: webDir,
        baseHref: baseHref,
        error: '--base-href должен начинаться и заканчиваться на /',
      );
    }
    return _Options(
      platform: platform,
      arch: arch,
      webDir: webDir,
      baseHref: baseHref,
    );
  }

  final String platform;
  final String arch;
  final String? webDir;
  final String baseHref;
  final String? error;
}
