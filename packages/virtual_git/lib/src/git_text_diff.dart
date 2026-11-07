/// Упрощённый unified diff двух многострочных текстов (для внешнего слоя
/// `git range-diff` при статусе `!`). Три контекстные строки.
library;

import 'dart:math' as math;

String gitUnifiedTextDiff(String aText, String bText, {int context = 3}) {
  final a = aText.split('\n');
  final b = bText.split('\n');
  final lcs = _longestCommonSubsequence(a, b);
  final hunks = <_Hunk>[];
  var i = 0;
  var j = 0;
  var k = 0;
  while (i < a.length || j < b.length) {
    if (k < lcs.length &&
        i < a.length &&
        j < b.length &&
        a[i] == b[j] &&
        a[i] == lcs[k]) {
      i++;
      j++;
      k++;
      continue;
    }
    final startA = i;
    final startB = j;
    while (i < a.length && (k >= lcs.length || a[i] != lcs[k])) {
      i++;
    }
    while (j < b.length && (k >= lcs.length || b[j] != lcs[k])) {
      j++;
    }
    if (startA < i || startB < j) {
      hunks.add(_Hunk(startA: startA, endA: i, startB: startB, endB: j));
    }
    if (k < lcs.length && i < a.length && j < b.length) {
      k++;
    }
  }
  if (hunks.isEmpty) return '';

  final out = StringBuffer();
  var prevCtxEndA = 0;
  var prevCtxEndB = 0;
  for (final h in hunks) {
    var ctxStartA = math.max(0, h.startA - context);
    var ctxStartB = math.max(0, h.startB - context);
    if (prevCtxEndA > 0 || prevCtxEndB > 0) {
      ctxStartA = math.min(ctxStartA, prevCtxEndA);
      ctxStartB = math.min(ctxStartB, prevCtxEndB);
    }
    final ctxEndA = math.min(a.length, h.endA + context);
    final ctxEndB = math.min(b.length, h.endB + context);

    final oldStart1 = ctxStartA + 1;
    final newStart1 = ctxStartB + 1;
    final oldCount = ctxEndA - ctxStartA;
    final newCount = ctxEndB - ctxStartB;
    out.writeln('@@ -$oldStart1,$oldCount +$newStart1,$newCount @@');

    for (var x = ctxStartA; x < h.startA; x++) {
      out.writeln(' ${a[x]}');
    }
    for (var x = h.startA; x < h.endA; x++) {
      out.writeln('-${a[x]}');
    }
    for (var x = h.startB; x < h.endB; x++) {
      out.writeln('+${b[x]}');
    }
    for (var x = h.endA; x < ctxEndA; x++) {
      out.writeln(' ${a[x]}');
    }

    prevCtxEndA = ctxEndA;
    prevCtxEndB = ctxEndB;
  }
  return out.toString();
}

final class _Hunk {
  const _Hunk({
    required this.startA,
    required this.endA,
    required this.startB,
    required this.endB,
  });

  final int startA;
  final int endA;
  final int startB;
  final int endB;
}

List<String> _longestCommonSubsequence(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  final dp = List.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
    growable: false,
  );
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      if (a[i] == b[j]) {
        dp[i][j] = dp[i + 1][j + 1] + 1;
      } else {
        dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1]);
      }
    }
  }
  final out = <String>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      out.add(a[i]);
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return out;
}
