import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Проверяет, что пути в backticks из документации действительно существуют.
///
/// Это ловит самый частый вид drift: файл переехал в пакет, а README или
/// WIDGET_BOOK продолжают указывать старый путь. Примеры вроде команд,
/// URL, шаблонов и внешних каталогов сборки намеренно пропускаются.
const _roots = [
  'lib/',
  'packages/',
  'test/',
  'tool/',
  'docs/',
  'android/',
  'windows/',
  'macos/',
  'ios/',
  '.github/',
  'assets/',
  'snap/',
  'agent/',
  'host/',
  'providers/',
  'core/',
  'features/',
  'app/',
];

const _rootFiles = {
  'README.md',
  'AGENTS.md',
  'CHANGELOG.md',
  'LICENSE',
  'pubspec.yaml',
  'pubspec.lock',
  'analysis_options.yaml',
};

const _ignoredPrefixes = [
  'build/',
  'dist/',
  '.dart_tool/',
  'canvaskit/',
  'lib/l10n/generated/',
];

/// Пути, которые документация называет будущими, а не существующими.
///
/// Список намеренно точный, а не префиксный: исключение не должно скрывать
/// опечатки в реальных путях. Когда пакет появится, строку нужно убрать.
const _plannedPaths = {'packages/pw_relay'};

void main() {
  test('paths in documentation exist', () {
    final missing = <String>{};
    for (final file in _documents()) {
      final text = file.readAsStringSync();
      for (final match in RegExp(r'`([^`\n]+)`').allMatches(text)) {
        final raw = match.group(1)!.trim();
        if (!_looksLikePath(raw)) continue;
        final path = raw.startsWith('./') ? raw.replaceFirst('./', '') : raw;
        if (_ignoredPrefixes.any(path.startsWith)) continue;
        if (_plannedPaths.contains(path)) continue;
        if (File(path).existsSync() || Directory(path).existsSync()) continue;
        missing.add('${file.path}: $raw');
      }
    }

    expect(
      missing,
      isEmpty,
      reason:
          'Документация ссылается на отсутствующие пути:\n'
          '${missing.join('\n')}',
    );
  });
}

Iterable<File> _documents() sync* {
  yield File('README.md');
  yield File('AGENTS.md');
  for (final entity in Directory('docs').listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.md')) yield entity;
  }
}

bool _looksLikePath(String value) {
  if (value.isEmpty) return false;
  if (value.contains(RegExp(r'[ *<>{}[\]$|=%#?]'))) return false;
  if (value.contains('://') || value.contains('...')) return false;
  if (value.startsWith('/') || value.startsWith('~')) return false;
  if (_rootFiles.contains(value)) return true;
  return _roots.any(value.startsWith);
}
