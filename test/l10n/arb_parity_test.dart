import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _readArb(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Set<String> _messageKeys(Map<String, dynamic> arb) => {
  for (final key in arb.keys)
    if (!key.startsWith('@')) key,
};

/// Исходники, где ищутся обращения к строкам. Генерация локализации
/// исключена: в ней есть геттер для каждого ключа, и проверка теряет смысл.
String _applicationCode() {
  final buffer = StringBuffer();
  for (final root in ['lib', 'packages']) {
    for (final entity in Directory(root).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.contains('/l10n/generated/')) continue;
      buffer.writeln(entity.readAsStringSync());
    }
  }
  return buffer.toString();
}

void main() {
  final en = _readArb('lib/l10n/app_en.arb');
  final ru = _readArb('lib/l10n/app_ru.arb');

  test('ru and en contain the same message keys', () {
    expect(_messageKeys(ru), _messageKeys(en));
  });

  test('every template message has a description in the template', () {
    final missing = [
      for (final key in _messageKeys(en))
        if (!(en['@$key'] is Map &&
            (en['@$key'] as Map)['description'] is String))
          key,
    ];
    expect(missing, isEmpty, reason: 'missing @key.description in app_en.arb');
  });

  test('every ru message has metadata with description', () {
    final missing = [
      for (final key in _messageKeys(ru))
        if (!(ru['@$key'] is Map &&
            (ru['@$key'] as Map)['description'] is String))
          key,
    ];
    expect(missing, isEmpty, reason: 'missing @key.description in app_ru.arb');
  });

  test('placeholders declared in en exist in ru', () {
    for (final key in _messageKeys(en)) {
      final meta = en['@$key'];
      if (meta is! Map || meta['placeholders'] is! Map) continue;
      final names = (meta['placeholders'] as Map).keys;
      final ruValue = ru[key] as String;
      for (final name in names) {
        expect(
          ruValue.contains('{$name}'),
          isTrue,
          reason: '$key lacks placeholder {$name} in ru',
        );
      }
    }
  });

  test('every message is used in the application code', () {
    final code = _applicationCode();
    final unused = [
      for (final key in _messageKeys(en))
        if (!RegExp('\\b${RegExp.escape(key)}\\b').hasMatch(code)) key,
    ];
    expect(unused, isEmpty, reason: 'unused l10n keys: ${unused.join(', ')}');
  });
}
