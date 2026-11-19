import 'dart:convert';
import 'dart:io';

import 'package:pw_agent/core/platform/platform_profile.dart';

/// Чтение текстового файла с данными о системе. null — файла нет или он недоступен.
typedef LocalFileReader = String? Function(String path);

/// Запуск служебной команды, которая сообщает версию системы.
/// null — команда не запустилась или завершилась ошибкой.
typedef LocalCommandRunner = String? Function(
  String executable,
  List<String> arguments,
);

/// Человекочитаемое название локальной системы: дистрибутив, ОС и версия.
///
/// Это только подпись для интерфейса. `HostOs` остаётся семейством
/// shell-диалекта и хранится в базе; здесь ничего не пишется и не меняет
/// выбор команд.
///
/// Данные о системе вычисляются один раз: чтение `/etc/os-release` и запуск
/// `getprop`/`sw_vers` не должны повторяться на каждый кадр списка хостов.
final class LocalSystemInfo {
  const LocalSystemInfo({required this.name, this.version, this.prettyName});

  /// Название без версии: «Ubuntu», «macOS», «Windows 11 Pro», «Android».
  final String name;

  /// Версия без названия: «24.04.1 LTS», «15.1.1», «14». Может быть null,
  /// если система не сообщила версию.
  final String? version;

  /// Готовая подпись от системы (например, `PRETTY_NAME` из os-release или
  /// строка Windows). Если она есть, [displayName] показывает её как есть:
  /// только система знает, где в названии версия, а где редакция.
  final String? prettyName;

  /// Подпись для интерфейса: «Ubuntu 24.04.1 LTS», «macOS 15.1.1»,
  /// «Windows 11 Pro 23H2», «Android 14».
  String get displayName {
    final pretty = prettyName?.trim();
    if (pretty != null && pretty.isNotEmpty) return pretty;
    final value = version?.trim();
    return value == null || value.isEmpty ? name : '$name $value';
  }

  /// Сведения о текущей системе. null — локального Host нет (iOS), и
  /// показывать нечего.
  static LocalSystemInfo? get current => _current;

  static final LocalSystemInfo? _current = detectLocalSystem(
    hasLocalHost: PlatformProfile.current.hasLocalHost,
    operatingSystem: Platform.operatingSystem,
    operatingSystemVersion: Platform.operatingSystemVersion,
  );
}

/// Определяет локальную систему по платформе и её данным.
///
/// Источники передаются снаружи, потому что ветки Android, macOS и Windows
/// нельзя проверить на одной машине в тестах. Без [readFile] и [run]
/// используются настоящие файлы и процессы.
///
/// Возвращает null, если локального Host нет (iOS): у такой платформы нет
/// ни shell, ни файловой системы, о которой стоило бы рассказывать.
LocalSystemInfo? detectLocalSystem({
  required bool hasLocalHost,
  required String operatingSystem,
  required String operatingSystemVersion,
  LocalFileReader? readFile,
  LocalCommandRunner? run,
}) {
  if (!hasLocalHost) return null;
  final read = readFile ?? _readTextFile;
  final exec = run ?? _runTextCommand;
  return switch (operatingSystem) {
    'android' => _android(exec),
    'linux' => _linux(operatingSystemVersion, read),
    'macos' => _macos(operatingSystemVersion, read, exec),
    'windows' => _windows(operatingSystemVersion, exec),
    _ => _generic(operatingSystem, operatingSystemVersion),
  };
}

/// Android сообщает только номер релиза через системное свойство.
/// `Platform.operatingSystemVersion` здесь — идентификатор сборки, а не версия
/// Android, поэтому его не используем.
LocalSystemInfo _android(LocalCommandRunner run) {
  final release =
      run('getprop', ['ro.build.version.release']) ??
      run('getprop', ['ro.build.version.release_or_codename']);
  return LocalSystemInfo(name: 'Android', version: release);
}

/// Linux: `PRETTY_NAME` уже содержит дистрибутив и версию в привычном виде
/// («Ubuntu 24.04.1 LTS», «Debian GNU/Linux 12 (bookworm)»). Если файла нет,
/// остаётся имя ядра из `uname`, чтобы подпись не была пустой.
LocalSystemInfo _linux(String operatingSystemVersion, LocalFileReader read) {
  for (final path in const ['/etc/os-release', '/usr/lib/os-release']) {
    final text = read(path);
    if (text == null) continue;
    final parsed = _parseOsRelease(text);
    if (parsed != null) return parsed;
  }
  return LocalSystemInfo(
    name: 'Linux',
    version: _kernelRelease(operatingSystemVersion),
  );
}

/// macOS: plist читается без запуска процесса, `sw_vers` — запасной вариант.
/// Если не сработало ни то ни другое, разбираем строку `Platform`, где версия
/// записана как «Version 15.1.1 (Build 24B91)».
LocalSystemInfo _macos(
  String operatingSystemVersion,
  LocalFileReader read,
  LocalCommandRunner run,
) {
  final plist = read('/System/Library/CoreServices/SystemVersion.plist');
  final parsed = plist == null ? null : _parseSystemVersionPlist(plist);
  if (parsed != null) return parsed;
  final name = run('sw_vers', ['-productName']);
  final version = run('sw_vers', ['-productVersion']);
  if (name != null && version != null) {
    return LocalSystemInfo(name: name, version: version);
  }
  final match = RegExp(r'Version\s+([0-9.]+)')
      .firstMatch(operatingSystemVersion.trim());
  return LocalSystemInfo(name: 'macOS', version: match?.group(1));
}

/// Windows: `Platform.operatingSystemVersion` уже содержит редакцию и сборку
/// («"Windows 11 Pro" 10.0 (Build 22631)»). Маркетинговую версию (23H2)
/// достаём из реестра: без неё сборка остаётся единственным номером.
LocalSystemInfo _windows(
  String operatingSystemVersion,
  LocalCommandRunner run,
) {
  final text = operatingSystemVersion.trim();
  final match = RegExp(r'^"(.+)"\s+[0-9.]+\s+\(Build\s+([0-9]+)\)$')
      .firstMatch(text);
  if (match == null) {
    return text.isEmpty
        ? const LocalSystemInfo(name: 'Windows')
        : LocalSystemInfo(name: 'Windows', prettyName: text);
  }
  var name = match.group(1)!;
  final build = int.tryParse(match.group(2)!);
  // В реестре Windows 11 всё ещё называется «Windows 10»; различает их сборка.
  if (build != null && build >= 22000 && name.startsWith('Windows 10')) {
    name = name.replaceFirst('Windows 10', 'Windows 11');
  }
  final displayVersion = _windowsDisplayVersion(run);
  return LocalSystemInfo(
    name: name,
    version: displayVersion ?? 'Build ${match.group(2)}',
    prettyName: displayVersion == null
        ? '$name (Build ${match.group(2)})'
        : '$name $displayVersion',
  );
}

/// Неизвестная платформа: показываем хотя бы системное имя из `dart:io`.
LocalSystemInfo _generic(
  String operatingSystem,
  String operatingSystemVersion,
) {
  final name = operatingSystem.isEmpty
      ? 'Unknown'
      : operatingSystem.replaceRange(0, 1, operatingSystem[0].toUpperCase());
  final version = operatingSystemVersion.trim();
  return LocalSystemInfo(name: name, version: version.isEmpty ? null : version);
}

/// Разбирает `/etc/os-release`. Значения в кавычках — по правилам shell.
/// Возвращает null, если в файле нет даже названия системы.
LocalSystemInfo? _parseOsRelease(String text) {
  final values = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final separator = trimmed.indexOf('=');
    if (separator <= 0) continue;
    final length = trimmed.length;
    final key = trimmed.replaceRange(separator, length, '').trim();
    values[key] = _unquoteOsRelease(
      trimmed.replaceRange(0, separator + 1, '').trim(),
    );
  }
  final name = values['NAME']?.trim();
  final pretty = values['PRETTY_NAME']?.trim();
  final version = values['VERSION_ID']?.trim() ?? values['VERSION']?.trim();
  if ((name == null || name.isEmpty) && (pretty == null || pretty.isEmpty)) {
    return null;
  }
  return LocalSystemInfo(
    name: name == null || name.isEmpty ? pretty! : name,
    version: version == null || version.isEmpty ? null : version,
    prettyName: pretty == null || pretty.isEmpty ? null : pretty,
  );
}

/// Снимает внешние кавычки и раскрывает экранирование, которое os-release
/// допускает внутри значений.
String _unquoteOsRelease(String value) {
  if (value.length < 2) return value;
  final quote = value[0];
  if ((quote != '"' && quote != "'") || value[value.length - 1] != quote) {
    return value;
  }
  final withoutFirst = value.replaceRange(0, 1, '');
  final length = withoutFirst.length;
  final body = withoutFirst.replaceRange(length - 1, length, '');
  return body
      .replaceAll(r'\"', '"')
      .replaceAll(r"\'", "'")
      .replaceAll(r'\\', r'\')
      .replaceAll(r'\$', r'$');
}

/// Разбирает XML plist `/System/Library/CoreServices/SystemVersion.plist`.
LocalSystemInfo? _parseSystemVersionPlist(String text) {
  final name = _plistString(text, 'ProductName');
  final version = _plistString(text, 'ProductVersion');
  if (name == null && version == null) return null;
  return LocalSystemInfo(name: name ?? 'macOS', version: version);
}

/// Значение `<key>key</key><string>value</string>`; пробелы и переводы строк
/// между элементами plist допускаются.
String? _plistString(String text, String key) {
  final match = RegExp(
    '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
  ).firstMatch(text);
  final value = match?.group(1)?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// Маркетинговая версия Windows из реестра: «23H2», «22H2» и т. п.
String? _windowsDisplayVersion(LocalCommandRunner run) {
  final output = run('reg', [
    'query',
    r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
    '/v',
    'DisplayVersion',
  ]);
  if (output == null) return null;
  final match = RegExp(r'DisplayVersion\s+REG_\w+\s+(\S+)').firstMatch(output);
  final value = match?.group(1)?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// Версия ядра из строки `Platform.operatingSystemVersion` на Linux:
/// «Linux 6.8.0-45-generic #...». Если формат другой, возвращает строку как есть.
String? _kernelRelease(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  final parts = text.split(RegExp(r'\s+'));
  return parts.length > 1 && parts.first == 'Linux' ? parts[1] : text;
}

String? _readTextFile(String path) {
  try {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  } on Object {
    // Подпись системы не стоит падения приложения: нет доступа — покажем
    // то, что даёт dart:io.
    return null;
  }
}

String? _runTextCommand(String executable, List<String> arguments) {
  try {
    final result = Process.runSync(executable, arguments);
    if (result.exitCode != 0) return null;
    final output = '${result.stdout}'.trim();
    return output.isEmpty ? null : output;
  } on Object {
    // Команды может не быть (BusyBox, песочница). Это не ошибка интерфейса.
    return null;
  }
}
