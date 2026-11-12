// ignore_for_file: avoid-top-level-members-in-tests
// Причина: version guard импортируют несколько тестовых файлов.

import 'dart:io';

/// Переменная включает дифференциальные тесты с настоящим bash.
///
/// `1` — требуется закреплённая версия bash, `latest` — запуск против
/// системного bash (отчёт о расхождениях).
const parityEnvironment = 'PW_PARITY';

/// Причина пропуска паритетных тестов с bash.
String? get bashParitySkipReason {
  final mode = Platform.environment[parityEnvironment];
  if (mode == null || mode.isEmpty) {
    return 'Set PW_PARITY=1 to run differential tests against bash 5.3';
  }
  if (mode == 'latest') return null;
  final result = Process.runSync(
    'bash',
    ['--version'],
    environment: const {'LC_ALL': 'C'},
  );
  final firstLine = '${result.stdout}'.split('\n').first;
  if (result.exitCode != 0 || !firstLine.contains('version 5.3.')) {
    return 'Differential tests require bash 5.3.x, found '
        '${firstLine.isEmpty ? 'unknown' : firstLine}';
  }
  return null;
}
