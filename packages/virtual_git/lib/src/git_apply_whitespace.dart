/// Режим сопоставления строк контекста при применении unified diff (как у `git apply`).
enum GitApplyWhitespaceMode {
  /// Только точное совпадение.
  exact,

  /// Игнорировать разницу в пробелах внутри строки (`--ignore-space-change`).
  ignoreSpaceChange,

  /// Игнорировать все пробельные символы при сравнении (`--ignore-whitespace`).
  ignoreAllWhitespace,
}

/// Политика trailing whitespace в добавляемых строках патча (`git apply --whitespace=…`).
enum GitApplyWhitespacePolicy {
  /// Не проверять и не сообщать (как `nowarn`).
  nowarn,

  /// Предупреждения в stderr, применение не блокируется.
  warn,

  /// Отклонить весь патч при любой ошибке пробелов в добавленных строках.
  error,

  /// Как [error]: при нескольких файлах в одном патче git тоже отклоняет целиком.
  errorAll,

  /// Убрать хвостовые пробелы в добавляемых строках и применить; предупреждение, если были исправления.
  fix,
}

/// Нормализует строку для режима [GitApplyWhitespaceMode.ignoreSpaceChange].
String normalizeApplyLineIgnoreSpaceChange(String line) {
  final trimmed = line.trimRight();
  return trimmed.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).join(' ');
}

/// Нормализует строку для режима [GitApplyWhitespaceMode.ignoreAllWhitespace].
String normalizeApplyLineIgnoreAllWhitespace(String line) =>
    line.replaceAll(RegExp(r'\s'), '');

/// Сравнивает две строки с учётом [mode] (окончания строки совпадают с git: сравнение по содержимому строки).
bool applyLinesEqual(
  String fileLine,
  String patchLine,
  GitApplyWhitespaceMode mode,
) {
  switch (mode) {
    case GitApplyWhitespaceMode.exact:
      return fileLine == patchLine;
    case GitApplyWhitespaceMode.ignoreSpaceChange:
      return normalizeApplyLineIgnoreSpaceChange(fileLine) ==
          normalizeApplyLineIgnoreSpaceChange(patchLine);
    case GitApplyWhitespaceMode.ignoreAllWhitespace:
      return normalizeApplyLineIgnoreAllWhitespace(fileLine) ==
          normalizeApplyLineIgnoreAllWhitespace(patchLine);
  }
}
