import 'dart:io';

import 'package:test/test.dart';

/// Git на виртуальном хосте не должен касаться реальной машины. Тест читает исходники `lib/**`
/// и падает, если там появились импорты процессов, файловой системы хоста или сети.
///
/// Ограничение то же, что у `virtual_host`: команда, которую запускает виртуальный Host, не может
/// через этот пакет добраться до ОС. Правило проверяется текстом, поэтому обходится только явным
/// изменением этого теста.
void main() {
  const forbiddenImports = [
    'dart:io',
    'dart:html',
    'dart:ffi',
    'dart:isolate',
    'dart:mirrors',
    'package:http/',
    'package:dio/',
    'package:web_socket_channel/',
    'package:dartssh2/',
    'package:flutter_pty/',
    'package:process/',
  ];
  final forbiddenUsage = RegExp(
    r'\b(Process|Socket|HttpClient|RawSocket|ServerSocket)\b[.(]',
  );

  test('в lib нет процессов, сети и файлов хоста', () {
    final root = Directory('lib');
    expect(
      root.existsSync(),
      isTrue,
      reason: 'каталог lib пакета должен существовать',
    );

    final violations = <String>[];
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        final isImport =
            line.startsWith('import ') || line.startsWith('export ');
        if (isImport && forbiddenImports.any(line.contains)) {
          violations.add('${entity.path}:${i + 1}: $line');
        }
        if (!line.startsWith('//') && forbiddenUsage.hasMatch(line)) {
          violations.add('${entity.path}:${i + 1}: $line');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
