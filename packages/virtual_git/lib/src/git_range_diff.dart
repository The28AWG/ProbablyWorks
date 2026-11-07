// ignore_for_file: avoid-substring
// Причина: разбор argv ревизий и SHA в ASCII, как в git.
/// Реализация `git range-diff`: сопоставление коммитов двух диапазонов по метрике
/// «diff синтетических патчей» и вывод в стиле git (с уточнениями в `docs/command_notes.md`).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_commit_codec.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_diff_options.dart';
import 'package:virtual_git/src/git_hungarian.dart';
import 'package:virtual_git/src/git_log.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_git/src/git_text_diff.dart';
import 'package:virtual_host/virtual_host.dart';

/// SHA-1 пустого дерева; для корневого коммита дифф к первому родителю — к пустому дереву.
const _gitEmptyTreeSha1 = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

/// Запуск `git range-diff`: разбор [args], сопоставление коммитов и вывод в [io.stdout].
Future<int> runRangeDiff(AppletIo io, List<String> args) async {
  const usage =
      'usage: git range-diff [<options>] <old-base>..<old-tip> <new-base>..<new-tip>\n'
      '   or: git range-diff [<options>] <old-tip>...<new-tip>\n'
      '   or: git range-diff [<options>] <base> <old-tip> <new-tip>\n';
  final parsed = parseGitArgs(args, gitRangeDiffParseOptions, usage: usage);

  final repo = await _openRepo(io);

  final pathspecs = <String>[];
  var operands = parsed.operands;
  final sep = operands.indexOf('--');
  if (sep >= 0) {
    pathspecs.addAll(operands.sublist(sep + 1));
    operands = operands.sublist(0, sep);
  }

  final parsedRanges = _parseRangeOperands(operands);
  if (parsedRanges == null) {
    throw const GitUsage(
      'fatal: need two commit ranges\n\n$usage',
      exitCode: 129,
    );
  }

  final cfRaw = parsed.value('creation-factor');
  final creationFactor = cfRaw == null
      ? 60
      : int.tryParse(cfRaw) ??
            (throw const GitUsage(
              'fatal: invalid --creation-factor\n',
              exitCode: 128,
            ));

  final leftOnly = parsed.has('left-only');
  final rightOnly = parsed.has('right-only');
  final wantPatch = parsed.has('patch') && !parsed.has('no-patch');
  final quiet = parsed.has('quiet');

  final leftRange = await _resolveRange(
    repo,
    spec: parsedRanges.leftSpec,
    rightTipHint: parsedRanges.rightTip,
  );
  final rightRange = await _resolveRange(
    repo,
    spec: parsedRanges.rightSpec,
    rightTipHint: parsedRanges.rightTip,
  );

  // Как у git без `--diff-merges`: merge-коммиты не сравниваются (флаг не парсится).
  final leftFiltered = [
    for (final e in leftRange)
      if (e.commit.parents.length <= 1) e,
  ];
  final rightFiltered = [
    for (final e in rightRange)
      if (e.commit.parents.length <= 1) e,
  ];

  final leftSynth = await _commitSynthList(repo, leftFiltered, pathspecs);
  final rightSynth = await _commitSynthList(repo, rightFiltered, pathspecs);

  final n = math.max(leftSynth.length, rightSynth.length);
  if (n == 0) {
    return _finishRangeDiff(parsed, anyChange: false);
  }

  final cost = List.generate(
    n,
    (_) => List<int>.filled(n, 1 << 28),
    growable: false,
  );
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (i < leftSynth.length && j < rightSynth.length) {
        cost[i][j] = _lineEditCost(leftSynth[i].text, rightSynth[j].text);
      } else if (i < leftSynth.length) {
        cost[i][j] = _unmatchedLeftCost(
          leftSynth[i].text.length,
          creationFactor,
        );
      } else if (j < rightSynth.length) {
        cost[i][j] = _unmatchedRightCost(
          rightSynth[j].text.length,
          creationFactor,
        );
      } else {
        cost[i][j] = 0;
      }
    }
  }

  final assign = hungarianMinAssignment(cost);
  final matchedLeft = <int>{};
  final matchedRight = <int>{};
  final pairs = <({int li, int ri})>[];
  for (var li = 0; li < leftSynth.length; li++) {
    final ri = assign[li];
    if (ri < rightSynth.length) {
      matchedLeft.add(li);
      matchedRight.add(ri);
      pairs.add((li: li, ri: ri));
    }
  }
  pairs.sort((a, b) => a.ri.compareTo(b.ri));

  final buffer = StringBuffer();
  var anyChange = false;

  void writePair(int li, int ri) {
    final l = leftSynth[li];
    final r = rightSynth[ri];
    final same = l.text == r.text;
    if (!same) anyChange = true;
    final status = same ? '=' : '!';
    if (leftOnly || rightOnly) return;
    buffer.writeln(
      '${li + 1}: ${_abbr(l.id.hex)} $status ${ri + 1}: ${_abbr(r.id.hex)} '
      '${_subject(r.commit.message)}',
    );
    if (wantPatch && !same) {
      buffer.write(
        gitUnifiedTextDiff(l.text, r.text, context: _unifiedContext(parsed)),
      );
    }
  }

  void writeLeftOnly(int li) {
    anyChange = true;
    if (rightOnly) return;
    final l = leftSynth[li];
    buffer.writeln(
      '${li + 1}: ${_abbr(l.id.hex)} < -:  ------- ${_subject(l.commit.message)}',
    );
  }

  void writeRightOnly(int ri) {
    anyChange = true;
    if (leftOnly) return;
    final r = rightSynth[ri];
    buffer.writeln(
      '-:  ------- > ${ri + 1}: ${_abbr(r.id.hex)} ${_subject(r.commit.message)}',
    );
  }

  for (final p in pairs) {
    writePair(p.li, p.ri);
  }
  for (var ri = 0; ri < rightSynth.length; ri++) {
    if (!matchedRight.contains(ri)) {
      writeRightOnly(ri);
    }
  }
  for (var li = 0; li < leftSynth.length; li++) {
    if (!matchedLeft.contains(li)) {
      writeLeftOnly(li);
    }
  }

  if (!quiet) {
    io.stdout.writeText(buffer.toString());
  }
  return _finishRangeDiff(parsed, anyChange: anyChange);
}

int _finishRangeDiff(GitInvocation parsed, {required bool anyChange}) =>
    parsed.has('exit-code') && anyChange ? 1 : 0;

Future<GitRepository> _openRepo(AppletIo io) async {
  final repository = await GitRepository.discover(io.cwd);
  if (repository == null) {
    throw const GitUsage(
      'fatal: not a git repository (or any of the parent directories): .git\n',
      exitCode: 128,
    );
  }
  return repository;
}

/// Разбор операндов без `git rev-parse`: формы из SYNOPSIS.
_ArgRanges? _parseRangeOperands(List<String> operands) {
  if (operands.isEmpty) return null;
  if (operands.length == 1) {
    final s = operands.single;
    final dots = s.indexOf('...');
    if (dots < 0) return null;
    final left = s.substring(0, dots).trim();
    final right = s.substring(dots + 3).trim();
    if (left.isEmpty || right.isEmpty) return null;
    return _ArgRanges(
      leftSpec: '$right..$left',
      rightSpec: '$left..$right',
      rightTip: right,
    );
  }
  if (operands.length == 2) {
    return _ArgRanges(
      leftSpec: operands.first,
      rightSpec: operands.last,
      rightTip: null,
    );
  }
  if (operands.length == 3) {
    return _ArgRanges(
      leftSpec: '${operands.first}..${operands[1]}',
      rightSpec: '${operands.first}..${operands.last}',
      rightTip: operands.last,
    );
  }
  if (operands.length == 4) {
    return _ArgRanges(
      leftSpec: '${operands.first}..${operands[1]}',
      rightSpec: '${operands[2]}..${operands.last}',
      rightTip: null,
    );
  }
  return null;
}

final class _ArgRanges {
  const _ArgRanges({
    required this.leftSpec,
    required this.rightSpec,
    this.rightTip,
  });

  final String leftSpec;
  final String rightSpec;

  /// Для `base..tip` с пустой правой частью: подсказка tip (форма «три ревизии»).
  final String? rightTip;
}

Future<List<GitLogEntry>> _resolveRange(
  GitRepository repo, {
  required String spec,
  required String? rightTipHint,
}) async {
  if (spec.contains('...')) {
    return const [];
  }
  final idx = spec.indexOf('..');
  if (idx < 0) {
    return const [];
  }
  var base = spec.substring(0, idx).trim();
  var tip = spec.substring(idx + 2).trim();

  if (tip.endsWith('^!')) {
    final inner = tip.substring(0, tip.length - 2);
    final id = await repo.revParse(inner);
    if (id == null) return const [];
    final obj = await repo.show(inner);
    if (obj == null) return const [];
    final c = const GitCommitCodec().decode(obj.bytes);
    if (c.parents.isEmpty) {
      return [GitLogEntry(objectId: id, commit: c)];
    }
    return repo.revListAncestryPath(
      base: c.parents.first.hex,
      tip: inner,
      excludeMerges: false,
    );
  }

  final parentN = RegExp(r'^(.*)\^(\d+)$');
  final parentMatch = parentN.firstMatch(tip);
  if (parentMatch != null) {
    final inner = parentMatch.group(1)!;
    final nth = int.parse(parentMatch.group(2)!);
    final id = await repo.revParse(inner);
    if (id == null) return const [];
    final obj = await repo.show(inner);
    if (obj == null) return const [];
    final c = const GitCommitCodec().decode(obj.bytes);
    if (nth < 1 || nth > c.parents.length) return const [];
    final parentHex = c.parents[nth - 1].hex;
    if (base.isEmpty) {
      return repo.revListAncestryPath(
        base: parentHex,
        tip: inner,
        excludeMerges: false,
      );
    }
    return repo.revListAncestryPath(
      base: base,
      tip: inner,
      excludeMerges: false,
    );
  }

  final nthParent = RegExp(r'^(.*)\^\-\d+$');
  if (nthParent.hasMatch(tip)) {
    final m = RegExp(r'^(.*)\^\-(\d+)$').firstMatch(tip);
    if (m == null) return const [];
    final commitSpec = m.group(1)!;
    final nth = int.parse(m.group(2)!);
    final id = await repo.revParse(commitSpec);
    if (id == null) return const [];
    final obj = await repo.show(commitSpec);
    if (obj == null) return const [];
    final c = const GitCommitCodec().decode(obj.bytes);
    if (nth < 1 || nth > c.parents.length) return const [];
    final parentHex = c.parents[nth - 1].hex;
    return repo.revListAncestryPath(
      base: parentHex,
      tip: commitSpec,
      excludeMerges: false,
    );
  }

  if (base.isEmpty) {
    final mergeBase = await repo.mergeBase(tip, rightTipHint ?? '');
    if (mergeBase == null) return const [];
    base = mergeBase.hex;
  } else if (tip.isEmpty) {
    tip = rightTipHint ?? '';
    if (tip.isEmpty) return const [];
  }

  return repo.revListAncestryPath(base: base, tip: tip, excludeMerges: false);
}

final class _SynthCommit {
  const _SynthCommit({
    required this.id,
    required this.commit,
    required this.text,
  });

  final GitObjectId id;
  final GitCommit commit;
  final String text;
}

Future<List<_SynthCommit>> _commitSynthList(
  GitRepository repo,
  List<GitLogEntry> entries,
  List<String> pathspecs,
) async {
  final out = <_SynthCommit>[];
  const codec = GitDiffCodec();
  for (final e in entries) {
    final parentHex = e.commit.parents.isEmpty
        ? _gitEmptyTreeSha1
        : e.commit.parents.first.hex;
    final entriesDiff = await repo.diffRevisions(
      parentHex,
      e.objectId.hex,
      pathspecs: pathspecs.isEmpty ? null : pathspecs,
    );
    final patch = codec.encode(entriesDiff);
    final buf = StringBuffer()
      ..writeln('author ${e.commit.author.name} <${e.commit.author.email}>')
      ..writeln()
      ..writeln(e.commit.message.trimRight())
      ..writeln()
      ..write(patch);
    out.add(
      _SynthCommit(id: e.objectId, commit: e.commit, text: buf.toString()),
    );
  }
  return out;
}

int _unmatchedLeftCost(int byteLen, int creationFactor) =>
    byteLen * (100 - creationFactor) ~/ 100;

int _unmatchedRightCost(int byteLen, int creationFactor) =>
    byteLen * creationFactor ~/ 100;

/// Редакционное расстояние по строкам (вставки/удаления/замены символа строки).
int _lineEditCost(String a, String b) {
  final la = a.split('\n');
  final lb = b.split('\n');
  final n = la.length;
  final m = lb.length;
  if (n == 0) return m;
  if (m == 0) return n;
  final dp = List.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
    growable: false,
  );
  for (var i = 0; i <= n; i++) {
    dp[i][0] = i;
  }
  for (var j = 0; j <= m; j++) {
    dp.first[j] = j;
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final c = la[i - 1] == lb[j - 1] ? 0 : 1;
      dp[i][j] = math.min(
        math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1),
        dp[i - 1][j - 1] + c,
      );
    }
  }
  return dp[n][m];
}

String _abbr(String hex) => hex.length <= 7 ? hex : hex.substring(0, 7);

String _subject(String message) {
  const split = LineSplitter();
  for (final line in split.convert(message)) {
    final t = line.trimRight();
    if (t.isNotEmpty) return t;
  }
  return '';
}

int _unifiedContext(GitInvocation parsed) {
  final u = parsed.value('unified');
  if (u == null || u.isEmpty) return 3;
  final n = int.tryParse(u);
  return n == null ? 3 : n.clamp(0, 1000000);
}
