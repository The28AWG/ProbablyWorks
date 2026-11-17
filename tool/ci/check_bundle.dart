import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Проверяет, что CI-сборка содержит наши файлы и актуальную версию.
///
/// Это не проверка поведения ОС и не запуск GUI: доверяем toolchain.
/// Проверяем только состав bundle — daemon, LICENSE, version.json и
/// ассеты. Если файл потерялся или версия не совпала с pubspec.yaml,
/// сборка считается сломанной.
///
/// Запуск:
///   dart run tool/ci/check_bundle.dart --platform=linux --root=bundle
Future<void> main(List<String> arguments) async {
  String? platform;
  String? rootPath;
  for (final argument in arguments) {
    if (argument.startsWith('--platform=')) {
      platform = argument.replaceFirst('--platform=', '');
    } else if (argument.startsWith('--root=')) {
      rootPath = argument.replaceFirst('--root=', '');
    } else {
      _fail('неизвестный аргумент: $argument');
    }
  }
  if (platform == null) _fail('не указан --platform');
  if (!const {'linux', 'windows', 'macos', 'ios'}.contains(platform)) {
    _fail('неизвестная платформа: $platform');
  }

  final root = Directory(rootPath ?? _defaultRoot(platform));
  if (!root.existsSync()) _fail('нет каталога сборки: ${root.path}');
  final gui = _resolveGui(platform, root);
  final expected = _readPubspecVersion();
  final errors = <String>[];

  final mainExecutable = _mainExecutable(platform, gui);
  if (!mainExecutable.existsSync()) {
    errors.add('${mainExecutable.path}: отсутствует исполняемый файл GUI');
  }

  // version.json есть только на части платформ. Свой build-info.json
  // пишет prepare_daemon; на macOS/iOS версию дополнительно сверяем по
  // Info.plist, который создаёт Xcode.
  final versionFiles = [
    ..._findByName(gui, 'version.json'),
    if (platform != 'ios') ..._findByName(gui, 'build-info.json'),
  ];
  if (platform != 'ios' && _findByName(gui, 'build-info.json').isEmpty) {
    errors.add('${gui.path}: отсутствует build-info.json');
  }
  if (versionFiles.isEmpty && platform != 'ios') {
    errors.add('${gui.path}: нет файла с версией сборки');
  } else {
    for (final file in versionFiles) {
      final value = _readVersionFile(file);
      if (value == null) {
        errors.add('${file.path}: не удалось разобрать версию');
        continue;
      }
      if (value.$1 != expected.$1 || value.$2 != expected.$2) {
        errors.add(
          '${file.path}: версия ${value.$1}+${value.$2}, '
          'ожидалась ${expected.$1}+${expected.$2}',
        );
      }
    }
  }

  if (platform == 'macos' || platform == 'ios') {
    final plist = File(
      platform == 'macos'
          ? p.join(gui.path, 'Contents', 'Info.plist')
          : p.join(gui.path, 'Info.plist'),
    );
    if (!plist.existsSync()) {
      errors.add('${plist.path}: отсутствует Info.plist');
    } else {
      final version = _plistValue(plist, 'CFBundleShortVersionString');
      final build = _plistValue(plist, 'CFBundleVersion');
      if (version != expected.$1 || build != expected.$2) {
        errors.add(
          '${plist.path}: версия ${version ?? '?'}+${build ?? '?'}, '
          'ожидалась ${expected.$1}+${expected.$2}',
        );
      }
    }
  }

  _requireFile(gui, 'LICENSE', errors, skip: platform == 'ios');
  _requireNotice(gui, errors);
  _requireFile(gui, 'Inter-Regular.ttf', errors, skip: false);
  _requireFile(gui, 'os_linux.svg', errors, skip: false);

  if (platform != 'ios') {
    final daemon = platform == 'macos'
        ? Directory(p.join(gui.path, 'Contents', 'MacOS', 'daemon'))
        : Directory(p.join(gui.path, 'daemon'));
    final executable = platform == 'windows'
        ? File(p.join(daemon.path, 'bin', 'pw_server.exe'))
        : File(p.join(daemon.path, 'bin', 'pw_server'));
    if (!executable.existsSync()) {
      errors.add('${executable.path}: отсутствует бинарник демона');
    } else if (!Platform.isWindows && !_isExecutable(executable)) {
      errors.add('${executable.path}: нет права на выполнение');
    } else {
      final help = await _runHelp(executable);
      if (help != null) errors.add(help);
    }
    if (_findContaining(daemon, 'sqlite3').isEmpty) {
      errors.add('${daemon.path}: нет нативной библиотеки sqlite3');
    }
    if (_findContaining(daemon, 'portable_pty').isEmpty) {
      errors.add('${daemon.path}: нет нативной библиотеки portable_pty');
    }
  }

  if (errors.isNotEmpty) {
    stderr
      ..writeln('CHECK FAILED platform=$platform')
      ..writeln(errors.join('\n'));
    exitCode = 1;
    return;
  }
  stdout.writeln(
    'CHECK OK platform=$platform version=${expected.$1}+${expected.$2} '
    'root=${gui.path}',
  );
}

String _defaultRoot(String platform) => switch (platform) {
  'linux' => 'build/linux/x64/release/bundle',
  'windows' => r'build/windows/x64/runner/Release',
  'macos' => 'build/macos/Build/Products/Release',
  'ios' => 'build/ios/iphonesimulator/Runner.app',
  _ => throw StateError('unknown platform $platform'),
};

File _mainExecutable(String platform, Directory gui) => switch (platform) {
  'linux' => File(p.join(gui.path, 'probably_works')),
  'windows' => File(p.join(gui.path, 'probably_works.exe')),
  'macos' => File(p.join(gui.path, 'Contents', 'MacOS', 'probably_works')),
  'ios' => File(p.join(gui.path, 'Runner')),
  _ => throw StateError('unknown platform $platform'),
};

Directory _resolveGui(String platform, Directory root) {
  if (platform != 'macos' && platform != 'ios') return root;
  if (root.path.endsWith('.app')) return root;
  final apps = root
      .listSync()
      .whereType<Directory>()
      .where((entity) => entity.path.endsWith('.app'))
      .toList();
  if (apps.length != 1) {
    _fail('ожидался один .app в ${root.path}, найдено ${apps.length}');
  }
  return apps.single;
}

(String, String) _readPubspecVersion() {
  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync()) _fail('нет pubspec.yaml');
  final match = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync());
  if (match == null) _fail('в pubspec.yaml нет version');
  final parts = match.group(1)!.split('+');
  return (parts.first, parts.length > 1 ? parts[1] : '0');
}

(String, String)? _readVersionFile(File file) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final version = decoded['version'];
    final build = decoded['build_number'];
    if (version is! String || build is! String) return null;
    return (version, build);
  } on Object {
    return null;
  }
}

void _requireFile(
  Directory root,
  String name,
  List<String> errors, {
  required bool skip,
}) {
  if (skip) return;
  if (_findByName(root, name).isEmpty) {
    errors.add('${root.path}: отсутствует $name');
  }
}

/// Flutter сжимает NOTICES в NOTICES.Z на не-web платформах, поэтому
/// принимаем оба варианта: конкретное имя зависит от версии toolchain.
void _requireNotice(Directory root, List<String> errors) {
  if (_findByName(root, 'NOTICES').isNotEmpty ||
      _findByName(root, 'NOTICES.Z').isNotEmpty) {
    return;
  }
  errors.add('${root.path}: отсутствует NOTICES или NOTICES.Z');
}

String? _plistValue(File file, String key) {
  try {
    final text = file.readAsStringSync();
    final match = RegExp(
      '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
    ).firstMatch(text);
    if (match != null) return match.group(1);
  } on Object {
    // Ниже пробуем plutil: plist может быть бинарным.
  }
  if (!Platform.isMacOS) return null;
  final result = Process.runSync('plutil', [
    '-extract',
    key,
    'raw',
    '-o',
    '-',
    file.path,
  ]);
  if (result.exitCode != 0) return null;
  return '${result.stdout}'.trim();
}

List<File> _findByName(Directory root, String name) {
  if (!root.existsSync()) return const [];
  return [
    for (final entity in root.listSync(recursive: true))
      if (entity is File && p.basename(entity.path) == name) entity,
  ];
}

List<File> _findContaining(Directory root, String part) {
  if (!root.existsSync()) return const [];
  return [
    for (final entity in root.listSync(recursive: true))
      if (entity is File && p.basename(entity.path).contains(part)) entity,
  ];
}

bool _isExecutable(File file) =>
    (file.statSync().mode & 0x49) != 0; // S_IXUSR | S_IXGRP | S_IXOTH

Future<String?> _runHelp(File executable) async {
  try {
    final result = await Process.run(executable.path, const [
      '--help',
    ]).timeout(const Duration(seconds: 15));
    if (result.exitCode != 0) {
      return '${executable.path}: --help завершился с кодом ${result.exitCode}';
    }
    final output = '${result.stdout}\n${result.stderr}';
    if (!output.contains('ProbablyWorks')) {
      return '${executable.path}: --help не похож на демон';
    }
    return null;
  } on Object catch (error) {
    return '${executable.path}: не запускается: $error';
  }
}

Never _fail(String message) {
  stderr.writeln('check_bundle: $message');
  exit(2);
}
