/// Построчный diff на LCS. Апплет `diff` и карточки правок агента считают одну функцию.
library;

enum DiffKind { same, add, remove }

class DiffLine {
  const DiffLine(this.kind, this.text);

  final DiffKind kind;
  final String text;
}

/// Построчный diff на основе LCS. Для больших файлов (больше [maxLines]
/// строк в любой версии) возвращает полную замену, чтобы не тратить память.
abstract final class LineDiff {
  const LineDiff._();
  static List<DiffLine> compute(
    String before,
    String after, {
    int maxLines = 600,
  }) {
    final a = before.isEmpty ? <String>[] : before.split('\n');
    final b = after.isEmpty ? <String>[] : after.split('\n');
    if (a.length > maxLines || b.length > maxLines) {
      return [
        for (final line in a) DiffLine(DiffKind.remove, line),
        for (final line in b) DiffLine(DiffKind.add, line),
      ];
    }
    final n = a.length;
    final m = b.length;
    final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        lcs[i][j] = a[i] == b[j]
            ? lcs[i + 1][j + 1] + 1
            : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
      }
    }
    final result = <DiffLine>[];
    var i = 0;
    var j = 0;
    while (i < n && j < m) {
      if (a[i] == b[j]) {
        result.add(DiffLine(DiffKind.same, a[i]));
        i++;
        j++;
      } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
        result.add(DiffLine(DiffKind.remove, a[i++]));
      } else {
        result.add(DiffLine(DiffKind.add, b[j++]));
      }
    }
    while (i < n) {
      result.add(DiffLine(DiffKind.remove, a[i++]));
    }
    while (j < m) {
      result.add(DiffLine(DiffKind.add, b[j++]));
    }
    return result;
  }
}
