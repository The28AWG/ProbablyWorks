/// Лимиты виртуального Host. Все значения в одном месте: инструменты и интерпретатор не держат своих констант.
///
/// Лимиты защищают приложение от модели, которая упирается в бесконечный вывод, гигантский файл или
/// зацикленную подстановку. Нарушение лимита — явная ошибка команды, а не молчаливое усечение данных.
final class VirtualLimits {
  const VirtualLimits({
    this.quotaBytes = 64 * 1024 * 1024,
    this.maxFileBytes = 8 * 1024 * 1024,
    this.maxOutputBytes = 1024 * 1024,
    this.maxCommandsPerRun = 1000,
    this.maxCommandLength = 8192,
    this.maxPipelineLength = 16,
    this.maxNestingDepth = 8,
    this.maxCompoundNesting = 32,
    this.maxSymlinkHops = 40,
    this.maxWalkEntries = 10000,
    this.runTimeout = const Duration(seconds: 30),
  });

  /// Суммарный размер файлов одного Host.
  final int quotaBytes;

  /// Размер одного файла.
  final int maxFileBytes;

  /// Байты вывода одного запуска (stdout и stderr вместе).
  final int maxOutputBytes;

  /// Число простых команд, которые интерпретатор выполнит за один запуск.
  final int maxCommandsPerRun;

  /// Длина строки команды в символах.
  final int maxCommandLength;

  /// Число команд в одном пайпе.
  final int maxPipelineLength;

  /// Глубина вложенных подстановок `$(...)` и обратных кавычек.
  final int maxNestingDepth;

  /// Глубина вложенных составных команд (`if`, циклы, `{ }`, `( )`, `case`). Больше лимита — явная ошибка
  /// разбора: рекурсивный разбор на очень глубоком вложении может исчерпать стек.
  final int maxCompoundNesting;

  /// Сколько симлинков разворачивается в одном пути (как `ELOOP` в POSIX).
  final int maxSymlinkHops;

  /// Сколько записей обходит одна операция обхода (find, grep, глобы).
  final int maxWalkEntries;

  /// Общее время одного запуска.
  final Duration runTimeout;
}
