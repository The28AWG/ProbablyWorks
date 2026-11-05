/// Ошибка разбора или неподдерживаемая конструкция shell. Текст совпадает с bash, потому что модель
/// обучена на bash и должна узнавать ошибку без перевода.
///
/// Код выхода для таких ошибок — 2, как у bash. Исполнение не начинается, если разбор скрипта не удался.
final class ShellSyntaxException implements Exception {
  /// Синтаксическая ошибка bash: `syntax error near unexpected token ...`.
  const ShellSyntaxException(this.message, {this.line = 1})
    : unsupported = false;

  /// Конструкция, которой нет в поддерживаемом подмножестве (`&`, `((...))`, `select` и т. п.). Отличается
  /// от синтаксической ошибки: скрипт корректный bash, но виртуальный shell его не выполнит.
  const ShellSyntaxException.unsupported(this.message, {this.line = 1})
    : unsupported = true;

  final String message;
  final int line;
  final bool unsupported;

  /// Текст для stderr. Префикс `bash: -c: line N:` совпадает с тем, что печатает `bash -c`.
  String get text => unsupported
      ? 'bash: -c: line $line: unsupported syntax: $message'
      : 'bash: -c: line $line: $message';

  /// Копия ошибки с другим номером строки. Лексер отдаёт строку, на которой нашёл проблему.
  ShellSyntaxException withLine(int line) => unsupported
      ? ShellSyntaxException.unsupported(message, line: line)
      : ShellSyntaxException(message, line: line);

  @override
  String toString() => text;
}

/// Команда `exit`: завершает текущую оболочку с кодом [code]. В подоболочке (пайп, `$(...)`) ловится
/// на её границе, поэтому `exit` не закрывает родительский скрипт.
final class ShellExit implements Exception {
  const ShellExit(this.code);

  final int code;
}

/// Ошибка выполнения, которая отменяет только текущую команду: сообщение, код 1, скрипт продолжается.
/// Например, деление на ноль в `$((...))`. В отличие от [ShellSyntaxException] возникает уже при запуске.
final class ShellRuntimeError implements Exception {
  const ShellRuntimeError(this.message);

  /// Текст без префикса: префикс `bash: line N:` добавляет интерпретатор.
  final String message;

  @override
  String toString() => message;
}

/// `break N`: прерывает N вложенных циклов. Поднимается по стеку до цикла, который его ловит; вне цикла
/// встроенная команда его не бросает. Не ошибка, поэтому не реализует отказ запуска.
final class ShellBreak implements Exception {
  const ShellBreak(this.levels);

  final int levels;
}

/// `continue N`: переходит к следующей итерации N-го охватывающего цикла. Устроено как [ShellBreak].
final class ShellContinue implements Exception {
  const ShellContinue(this.levels);

  final int levels;
}

/// `return N` внутри функции: завершает её с кодом [status]. Ловится на границе вызова функции.
final class ShellReturn implements Exception {
  const ShellReturn(this.status);

  final int status;
}

/// Превышен лимит запуска: время, число команд, размер подстановки или число записей глоба.
/// Прерывает весь запуск. [exitCode] — 124 для таймаута (как у `timeout`), иначе 1.
final class ShellLimitExceeded implements Exception {
  const ShellLimitExceeded(this.message, {this.exitCode = 1});

  final String message;
  final int exitCode;

  @override
  String toString() => message;
}
