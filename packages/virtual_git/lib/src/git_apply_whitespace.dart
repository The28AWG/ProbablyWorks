/// Режим сопоставления строк контекста при применении unified diff (как у `git apply`).
enum GitApplyWhitespaceMode {
  /// Только точное совпадение.
  exact,

  /// Игнорировать разницу в пробелах внутри строки (`--ignore-space-change`).
  ignoreSpaceChange,

  /// Игнорировать все пробельные символы при сравнении (`--ignore-whitespace`).
  ignoreAllWhitespace,
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
