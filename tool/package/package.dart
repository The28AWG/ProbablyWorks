import 'dart:ffi';
import 'dart:io';

/// Собирает и упаковывает desktop-приложение через Fastforge.
///
/// Примеры:
/// `dart run tool/package/package.dart`
/// `dart run tool/package/package.dart linux appimage,deb`
/// `dart run tool/package/package.dart windows exe --no-clean`
///
/// Fastforge устанавливается глобально и не входит в зависимости проекта:
/// его старый `archive` конфликтует с `virtual_git`.
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

  final platform = options.platform ?? _hostPlatform();
  final targets = options.targets ?? _defaultTargets[platform];
  if (targets == null || targets.isEmpty) {
    stderr.writeln('Нет формата упаковки по умолчанию для $platform.');
    exitCode = 2;
    return;
  }

  final fastforge = await _findFastforge();
  if (fastforge == null) {
    stderr
      ..writeln('fastforge не найден.')
      ..writeln('Установите: dart pub global activate fastforge 0.6.14')
      ..writeln('Затем добавьте \$HOME/.pub-cache/bin в PATH.');
    exitCode = 2;
    return;
  }

  final hook = '${_dartPath()} run tool/package/prepare_daemon.dart';
  final args = [
    'package',
    '--platform',
    platform,
    '--targets',
    targets.join(','),
    '--hook-pre',
    hook,
    if (!options.clean) '--skip-clean',
  ];
  stdout.writeln('> $fastforge ${args.join(' ')}');
  final process = await Process.start(
    fastforge,
    args,
    mode: ProcessStartMode.inheritStdio,
    // appimagetool не угадывает архитектуру AppDir и без ARCH отказывается
    // собирать образ.
    environment: platform == 'linux' ? {'ARCH': _linuxArch()} : null,
  );
  exitCode = await process.exitCode;
}

const _usage = '''
Использование: dart run tool/package/package.dart [platform] [targets] [--no-clean]

platform  linux, macos или windows (по умолчанию текущая ОС)
targets   список форматов через запятую:
          linux   — appimage,deb,tar.gz,zip
          windows — exe,zip
          macos   — dmg,zip
--no-clean  не запускать flutter clean перед сборкой
''';

const _defaultTargets = {
  'linux': ['appimage', 'deb', 'tar.gz'],
  'windows': ['exe', 'zip'],
  'macos': ['dmg', 'zip'],
};

final class _Options {
  const _Options({this.platform, this.targets, this.clean = true, this.error});

  factory _Options.parse(List<String> arguments) {
    String? platform;
    List<String>? targets;
    var clean = true;
    for (final argument in arguments) {
      if (argument == '--no-clean') {
        clean = false;
        continue;
      }
      if (argument.startsWith('--platform=')) {
        platform = argument.replaceFirst('--platform=', '');
        continue;
      }
      if (argument.startsWith('--targets=')) {
        targets = _splitTargets(argument.replaceFirst('--targets=', ''));
        continue;
      }
      if (argument.startsWith('-')) {
        return _Options(error: 'Неизвестный флаг: $argument');
      }
      if (platform == null) {
        platform = argument;
      } else if (targets == null) {
        targets = _splitTargets(argument);
      } else {
        return _Options(error: 'Лишний аргумент: $argument');
      }
    }
    return _Options(platform: platform, targets: targets, clean: clean);
  }

  final String? platform;
  final List<String>? targets;
  final bool clean;
  final String? error;
}

List<String> _splitTargets(String value) => value
    .split(',')
    .map((target) => target.trim())
    .where((target) => target.isNotEmpty)
    .toList();

String _hostPlatform() {
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  throw UnsupportedError('Неподдерживаемая desktop-платформа');
}

/// Ищет `fastforge` в PATH и возвращает путь к исполняемому файлу.
Future<String?> _findFastforge() async {
  try {
    final result = await Process.run('fastforge', ['--version']);
    return result.exitCode == 0 ? 'fastforge' : null;
  } on ProcessException {
    return null;
  }
}

String _dartPath() => Platform.resolvedExecutable.replaceAll(r'\', '/');

/// Архитектура для appimagetool в его нотации.
String _linuxArch() {
  final abi = Abi.current();
  if (abi == Abi.linuxArm64) return 'aarch64';
  if (abi == Abi.linuxArm) return 'armhf';
  return 'x86_64';
}
