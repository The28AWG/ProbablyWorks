import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Импорты, которые не должны появляться в продакшен-коде клиента:
/// монолитное ядро агента. Удалённые пакеты сюда не входят: их отсутствие
/// и так проверяет анализатор зависимостей.
const _forbidden = <String>['package:pw_agent/src/', 'AgentHub'];

void main() {
  test('клиент не импортирует монолитное ядро агента', () {
    final violations = <String>[];
    for (final directory in [
      Directory('lib'),
      Directory('packages/pw_client/lib'),
    ]) {
      for (final file in directory.listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final lines = file.readAsLinesSync();
        for (var index = 0; index < lines.length; index++) {
          final line = lines[index];
          if (line.trimLeft().startsWith('//')) continue;
          for (final pattern in _forbidden) {
            if (line.contains(pattern)) {
              violations.add('${file.path}:${index + 1}: $pattern');
            }
          }
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('клиент не зависит от pw_server в продакшен-коде', () {
    final violations = <String>[];
    for (final directory in [
      Directory('lib'),
      Directory('packages/pw_client/lib'),
    ]) {
      for (final file in directory.listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final lines = file.readAsLinesSync();
        for (var index = 0; index < lines.length; index++) {
          if (lines[index].contains('package:pw_server/')) {
            violations.add('${file.path}:${index + 1}');
          }
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
