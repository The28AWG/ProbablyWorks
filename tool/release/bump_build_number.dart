/// Увеличивает сквозной номер сборки `+N` в `pubspec.yaml`.
///
/// Номер общий для релизов и дистрибуций: каждый запуск CI вызывает этот
/// скрипт один раз, коммитит результат в `main` и собирает именно эту версию.
/// Номер растёт монотонно и не переиспользуется, поэтому пропуски допустимы.
///
/// Запуск: `dart run tool/release/bump_build_number.dart [--marketing X.Y.Z]`.
/// Без `--marketing` сохраняется маркетинговая версия из файла. Новая версия
/// печатается в stdout, чтобы workflow мог передать её дальше.
library;

import 'dart:io';

/// Строка `version:` в `pubspec.yaml`. Захватывает только значение: `\S+`
/// останавливается на `\r`, поэтому CRLF-окончание строки не затрагивается.
final _versionLine = RegExp(r'^version:[ \t]*(\S+)', multiLine: true);

/// Допустимая версия: `X.Y.Z+N`, где `N` — неотрицательное целое.
final _versionValue = RegExp(r'^(\d+\.\d+\.\d+)\+(\d+)$');

/// Возвращает текст `pubspec.yaml` с увеличенным номером сборки.
///
/// Если [marketingVersion] задан, маркетинговая часть заменяется на него.
/// Бросает [FormatException], если строки `version:` нет или она не в формате
/// `X.Y.Z+N`. Молча пропустить номер нельзя: это привело бы к повтору
/// `versionCode`, который Google Play уже не примет.
String bumpBuildNumber(String pubspec, {String? marketingVersion}) {
  final line = _versionLine.firstMatch(pubspec);
  if (line == null) {
    throw const FormatException('В pubspec.yaml нет строки version:');
  }
  final current = _versionValue.firstMatch(line.group(1)!);
  if (current == null) {
    throw FormatException(
      'Версия ${line.group(1)} не соответствует формату X.Y.Z+N',
    );
  }
  final marketing = marketingVersion ?? current.group(1)!;
  if (!_versionValue.hasMatch('$marketing+0')) {
    throw FormatException('Некорректная маркетинговая версия: $marketing');
  }
  final next = int.parse(current.group(2)!) + 1;
  final value = line.group(1)!;
  final valueStart = line.end - value.length;
  return pubspec.replaceRange(valueStart, line.end, '$marketing+$next');
}

/// Точка входа: читает `pubspec.yaml`, записывает обновлённую версию и печатает её.
void main(List<String> args) {
  var path = 'pubspec.yaml';
  String? marketing;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--marketing':
        marketing = args[++i];
      case '--path':
        path = args[++i];
      default:
        stderr.writeln('Неизвестный аргумент: ${args[i]}');
        exit(64);
    }
  }
  final file = File(path);
  final updated = bumpBuildNumber(
    file.readAsStringSync(),
    marketingVersion: marketing,
  );
  file.writeAsStringSync(updated);
  final version = _versionLine.firstMatch(updated)!.group(1);
  stdout.writeln(version);
}
