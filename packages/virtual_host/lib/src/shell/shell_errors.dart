/// Ошибка разбора или неподдерживаемая конструкция shell. Текст совпадает с bash, потому что модель
/// обучена на bash и должна узнавать ошибку без перевода.
///
/// Код выхода для таких ошибок — 2, как у bash. Исполнение не начинается, если разбор скрипта не удался.
final class ShellSyntaxException implements Exception {
  /// Синтаксическая ошибка bash: `syntax error near unexpected token ...`.
  const ShellSyntaxException(this.message, {this.line = 1})
    : unsupported = false;

  /// Конструкция, которой нет в поддерживаемом подмножестве (`&`, `coproc`, `shopt` и т. п.). Отличается
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

/// Ошибка раскрытия параметра, которая завершает оболочку: `set -u` на неустановленной переменной,
/// `${NAME:?текст}`, неверная косвенность, `${}`. Интерпретатор печатает `bash: line N: [message]` и
/// прерывает текущую оболочку (в подоболочке — только её) с кодом [exitCode].
///
/// Код выхода совпадает с bash: 127 для `set -u` и `${NAME:?}`, 1 для остальных. В отличие от
/// [ShellRuntimeError] команда не продолжается: как и в bash, скрипт после такой ошибки не выполняется.
final class ShellParamError implements Exception {
  const ShellParamError(
    this.message, {
    required this.exitCode,
    this.reported = false,
  });

  /// Текст без префикса `bash: line N:`: например, `x: unbound variable`.
  final String message;

  /// Код выхода оболочки.
  final int exitCode;

  /// Сообщение уже напечатано командой, в которой возникла ошибка. Ошибка всплывает через вызовы функций,
  /// и без этого флага команда-вызов напечатала бы её второй раз.
  final bool reported;

  @override
  String toString() => message;
}

/// Ошибка выполнения одной команды: сообщение и код 1, скрипт продолжается. Так ведут себя `((...))` и
/// `let`. Ошибка внутри раскрытия слова (`$((1/0))`, `a[-9]=1`) в bash прерывает оболочку: расширитель
/// и присваивание переводят её в [ShellParamError]. В отличие от [ShellSyntaxException] возникает уже
/// при запуске.
final class ShellRuntimeError implements Exception {
  const ShellRuntimeError(this.message);

  /// Текст без префикса: префикс `bash: line N:` добавляет интерпретатор.
  final String message;

  @override
  String toString() => message;
}

/// `break N`: прерывает N вложенных циклов. Поднимается по стеку до цикла, который его ловит; вне цикла
/// встроенная команда его не бросает. Не ошибка, поэтому не реализует отказ запуска.
/// [status] — код цикла, который остановился последним. У обычного `break` это 0. Недопустимый счётчик
/// (`break 0`) останавливает все циклы с кодом 1.
final class ShellBreak implements Exception {
  const ShellBreak(this.levels, {this.status = 0});

  final int levels;
  final int status;
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

/// Отмена запуска: подписчик потока закрыл его. [signal] — `INT` (код 130) или `TERM` (код 143).
/// Ловушка этого сигнала выполняется, затем оболочка завершается. Пустая ловушка сигнал не
/// возобновляет: вызывающий уже перестал читать вывод.
final class ShellCancelled implements Exception {
  const ShellCancelled(this.signal);

  final String signal;

  /// Код выхода bash для сигнала: 128 + номер (`INT` — 2, `TERM` — 15).
  int get code => signal == 'TERM' ? 143 : 130;

  @override
  String toString() => signal;
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
