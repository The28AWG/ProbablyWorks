/// Unified diff двух текстов. Соседние правки ближе чем `2 * context`
/// строк склеиваются в один hunk: `format-patch --range-diff` тогда
/// получает один блок `@@ Metadata`, а не заголовок на каждое отличие.
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
  }
  if (hunks.isEmpty) return '';

  final groups = <List<_Hunk>>[];
  for (final hunk in hunks) {
    if (groups.isEmpty || hunk.startA - groups.last.last.endA > context * 2) {
      groups.add([hunk]);
    } else {
      groups.last.add(hunk);
    }
  }

  final out = StringBuffer();
  for (final group in groups) {
    final first = group.first;
    final last = group.last;
    final ctxStartA = math.max(0, first.startA - context);
    final ctxStartB = math.max(0, first.startB - context);
    final ctxEndA = math.min(a.length, last.endA + context);
    final ctxEndB = math.min(b.length, last.endB + context);
    out.writeln(
      '@@ -${ctxStartA + 1},${ctxEndA - ctxStartA} '
      '+${ctxStartB + 1},${ctxEndB - ctxStartB} @@',
    );

    var aCursor = ctxStartA;
    var bCursor = ctxStartB;
    for (final hunk in group) {
      while (aCursor < hunk.startA && bCursor < hunk.startB) {
        out.writeln(' ${a[aCursor]}');
        aCursor++;
        bCursor++;
      }
      while (aCursor < hunk.startA) {
        out.writeln(' ${a[aCursor]}');
        aCursor++;
      }
      while (bCursor < hunk.startB) {
        out.writeln(' ${b[bCursor]}');
        bCursor++;
      }
      for (var x = hunk.startA; x < hunk.endA; x++) {
        out.writeln('-${a[x]}');
      }
      for (var x = hunk.startB; x < hunk.endB; x++) {
        out.writeln('+${b[x]}');
      }
      aCursor = hunk.endA;
      bCursor = hunk.endB;
    }
    while (aCursor < ctxEndA && bCursor < ctxEndB) {
      out.writeln(' ${a[aCursor]}');
      aCursor++;
      bCursor++;
    }
    while (aCursor < ctxEndA) {
      out.writeln(' ${a[aCursor]}');
      aCursor++;
    }
    while (bCursor < ctxEndB) {
      out.writeln(' ${b[bCursor]}');
      bCursor++;
    }
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
