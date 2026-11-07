/// Минимальное взвешенное совершенное сопоставление на квадратной матрице
/// (алгоритм венгерского метода; достаточно для `git range-diff`).
library;

/// Возвращает назначение столбца для каждой строки [0..n) при минимальной сумме.
/// [cost] — квадратная матрица размера [n]×[n], неотрицательные целые.
List<int> hungarianMinAssignment(List<List<int>> cost) {
  final n = cost.length;
  assert(n > 0);
  for (final row in cost) {
    assert(row.length == n);
  }

  // Потенциалы (u — строки, v — столбцы).
  final u = List<int>.filled(n + 1, 0);
  final v = List<int>.filled(n + 1, 0);
  final p = List<int>.filled(n + 1, 0); // matching: column -> row
  final way = List<int>.filled(n + 1, 0);

  for (var i = 1; i <= n; i++) {
    p[0] = i;
    var j0 = 0;
    final minv = List<int>.filled(n + 1, 0);
    final used = List<bool>.filled(n + 1, false);
    for (var j = 0; j <= n; j++) {
      minv[j] = 1 << 30;
    }
    do {
      used[j0] = true;
      final i0 = p[j0];
      var delta = 1 << 30;
      var j1 = 0;
      for (var j = 1; j <= n; j++) {
        if (!used[j]) {
          final cur = cost[i0 - 1][j - 1] - u[i0] - v[j];
          if (cur < minv[j]) {
            minv[j] = cur;
            way[j] = j0;
          }
          if (minv[j] < delta) {
            delta = minv[j];
            j1 = j;
          }
        }
      }
      for (var j = 0; j <= n; j++) {
        if (used[j]) {
          u[p[j]] += delta;
          v[j] -= delta;
        } else {
          minv[j] -= delta;
        }
      }
      j0 = j1;
    } while (p[j0] != 0);
    do {
      final j1 = way[j0];
      p[j0] = p[j1];
      j0 = j1;
    } while (j0 != 0);
  }

  final answer = List<int>.filled(n, 0);
  for (var j = 1; j <= n; j++) {
    if (p[j] != 0) {
      answer[p[j] - 1] = j - 1;
    }
  }
  return answer;
}
