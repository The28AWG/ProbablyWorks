part of '../git_branch_command.dart';

/// Список веток, сортировка и ширина колонок.
Future<int> _list(
  AppletIo io,
  GitRepository repo,
  GitInvocation parsed, {
  required _Columns columns,
}) async {
  final remotesOnly = parsed.has('remotes') && !parsed.has('all');
  final includeRemotes = parsed.has('remotes') || parsed.has('all');
  final rows = <_Ref>[];
  if (!remotesOnly) {
    rows.addAll(await _load(repo, 'refs/heads'));
    final head = await repo.readReference('HEAD');
    if (head != null && head.isDirect) {
      final id = head.objectId;
      if (id != null) {
        rows.add(
          _Ref(
            refname: 'HEAD',
            objectId: id,
            commit: await _commit(repo, id),
            detached: true,
            current: true,
            symref: null,
            description: await _detachedDescription(repo, id),
          ),
        );
      }
    } else {
      final current = head?.targetReferenceName;
      for (final row in rows) {
        row.current = row.refname == current;
      }
    }
  }
  if (includeRemotes) rows.addAll(await _load(repo, 'refs/remotes'));
  final ignoreCase = parsed.has('ignore-case');
  final patterns = parsed.operands;
  final filtered = <_Ref>[
    for (final row in rows)
      if (_matches(row, patterns, ignoreCase: ignoreCase)) row,
  ];
  final reach = _Reach(repo);
  final selected = await _filter(repo, filtered, parsed, reach);
  final verbose = parsed.count('verbose');
  final abbrev = _abbrev(parsed);
  final color = _color(parsed);
  var maxWidth = 0;
  if (verbose > 0) {
    for (final row in selected) {
      final width = _nameWidth(row, remoteBonus: !remotesOnly);
      if (width > maxWidth) maxWidth = width;
    }
  }
  final configured = await repo.configGet('branch.sort');
  final keys = <String>[
    if (configured != null && configured.isNotEmpty) configured,
    ...parsed.valuesOf('sort'),
  ];
  selected.sort(
    (left, right) => _compare(left, right, keys: keys, ignoreCase: ignoreCase),
  );
  for (final row in selected) {
    await reach.describe(row);
  }
  final format =
      parsed.value('format') ??
      _defaultFormat(
        color: color,
        verbose: verbose,
        abbrev: abbrev,
        maxWidth: maxWidth,
        remotePrefix: remotesOnly ? '' : 'remotes/',
      );
  final lines = <String>[];
  for (final row in selected) {
    final text = _render(format, row, abbrev: abbrev, reach: reach);
    if (text.isEmpty && parsed.has('omit-empty')) continue;
    lines.add(text);
  }
  if (columns.mode == _Col.off || columns.mode == _Col.plain) {
    for (final line in lines) {
      io.stdout.writeText('$line\n');
    }
    return 0;
  }
  io.stdout.writeText(
    _layout(
      lines,
      width: _termWidth(io) - 1,
      across: columns.mode == _Col.across,
      dense: columns.dense,
    ),
  );
  return 0;
}

Future<List<_Ref>> _load(GitRepository repo, String prefix) async {
  final loaded = <_Ref>[];
  for (final info in await repo.references(prefix: prefix)) {
    final stored = await repo.readReference(info.referenceName);
    loaded.add(
      _Ref(
        refname: info.referenceName,
        objectId: info.objectId,
        commit: await _commit(repo, info.objectId),
        detached: false,
        current: false,
        symref: stored?.targetReferenceName,
        description: '',
      ),
    );
  }
  return loaded;
}

Future<GitCommit?> _commit(GitRepository repo, GitObjectId id) async {
  final object = await repo.show(id.hex);
  if (object == null || object.type != GitObjectType.commit) return null;
  return const GitCommitCodec().decode(object.bytes);
}

Future<String> _detachedDescription(GitRepository repo, GitObjectId id) async {
  final entries = await repo.reflog();
  var label = id.hex;
  var at = true;
  if (entries.isNotEmpty) {
    at = entries.first.newObjectId == id;
    for (final entry in entries) {
      const marker = ' to ';
      final atSign = entry.message.lastIndexOf(marker);
      if (atSign < 0) continue;
      label = _slice(
        entry.message,
        atSign + marker.length,
        entry.message.length,
      );
      break;
    }
  }
  final word = at ? 'at' : 'from';
  return '(HEAD detached $word $label)';
}

bool _matches(_Ref row, List<String> patterns, {required bool ignoreCase}) {
  if (patterns.isEmpty) return true;
  final names = row.detached
      ? <String>[row.description, 'HEAD']
      : <String>[_matchName(row.refname)];
  for (final pattern in patterns) {
    for (final name in names) {
      if (_wild(pattern, name, ignoreCase: ignoreCase)) return true;
    }
  }
  return false;
}

String _matchName(String refname) {
  for (final prefix in const [
    'refs/heads/',
    'refs/remotes/',
    'refs/tags/',
    'refs/',
  ]) {
    if (refname.startsWith(prefix)) {
      return _slice(refname, prefix.length, refname.length);
    }
  }
  return refname;
}

Future<List<_Ref>> _filter(
  GitRepository repo,
  List<_Ref> rows,
  GitInvocation parsed,
  _Reach reach,
) async {
  final contains = await _revs(repo, parsed.valuesOf('contains'));
  final absent = await _revs(repo, parsed.valuesOf('no-contains'));
  final merged = await _revs(repo, parsed.valuesOf('merged'));
  final unmerged = await _revs(repo, parsed.valuesOf('no-merged'));
  final points = await _revs(repo, parsed.valuesOf('points-at'));
  final kept = <_Ref>[];
  for (final row in rows) {
    final tip = row.objectId.hex;
    if (contains.isNotEmpty && !await _anyAncestor(reach, tip, contains)) {
      continue;
    }
    if (absent.isNotEmpty && await _anyAncestor(reach, tip, absent)) continue;
    if (merged.isNotEmpty && !await _anyContains(reach, merged, tip)) continue;
    if (unmerged.isNotEmpty && await _anyContains(reach, unmerged, tip)) {
      continue;
    }
    if (points.isNotEmpty && !points.contains(tip)) continue;
    kept.add(row);
  }
  return kept;
}

Future<List<String>> _revs(GitRepository repo, List<String> names) async {
  final ids = <String>[];
  for (final name in names) {
    final id = await repo.revParse(name);
    if (id == null) {
      throw GitUsage('error: malformed object name $name\n');
    }
    ids.add(id.hex);
  }
  return ids;
}

Future<bool> _anyAncestor(
  _Reach reach,
  String tip,
  List<String> commits,
) async {
  final set = await reach.of(tip);
  for (final commit in commits) {
    if (set.contains(commit)) return true;
  }
  return false;
}

Future<bool> _anyContains(
  _Reach reach,
  List<String> tips,
  String commit,
) async {
  for (final tip in tips) {
    if ((await reach.of(tip)).contains(commit)) return true;
  }
  return false;
}

int _compare(
  _Ref left,
  _Ref right, {
  required List<String> keys,
  required bool ignoreCase,
}) {
  if (left.detached != right.detached) return left.detached ? -1 : 1;
  final order = keys.isEmpty ? const <String>['refname'] : keys;
  for (var index = order.length - 1; index >= 0; index--) {
    final compared = _compareKey(
      order[index],
      left,
      right,
      ignoreCase: ignoreCase,
    );
    if (compared != 0) return compared;
  }
  return _text(left.refname, right.refname, ignoreCase: ignoreCase);
}

int _compareKey(String raw, _Ref left, _Ref right, {required bool ignoreCase}) {
  var key = raw;
  var reverse = false;
  if (key.startsWith('-')) {
    reverse = true;
    key = _slice(key, 1, key.length);
  }
  final compared = switch (key) {
    'refname' => _text(left.refname, right.refname, ignoreCase: ignoreCase),
    'objectname' => left.objectId.hex.compareTo(right.objectId.hex),
    'version:refname' => _version(
      left.refname,
      right.refname,
      ignoreCase: ignoreCase,
    ),
    'authordate' ||
    'committerdate' ||
    'creatordate' ||
    'taggerdate' => _dateOf(left, key).compareTo(_dateOf(right, key)),
    _ => throw GitUsage('fatal: unknown field name: $key\n', exitCode: 128),
  };
  return reverse ? -compared : compared;
}

int _dateOf(_Ref row, String key) {
  final commit = row.commit;
  if (commit == null) return 0;
  final signature = key == 'authordate' ? commit.author : commit.committer;
  return signature.timestampSeconds;
}

int _text(String left, String right, {required bool ignoreCase}) {
  if (!ignoreCase) return left.compareTo(right);
  return left.toLowerCase().compareTo(right.toLowerCase());
}

int _version(String left, String right, {required bool ignoreCase}) {
  final a = ignoreCase ? left.toLowerCase() : left;
  final b = ignoreCase ? right.toLowerCase() : right;
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final aDigit = _isDigit(a.codeUnitAt(i));
    final bDigit = _isDigit(b.codeUnitAt(j));
    if (aDigit && bDigit) {
      final aStart = i;
      final bStart = j;
      while (i < a.length && _isDigit(a.codeUnitAt(i))) {
        i++;
      }
      while (j < b.length && _isDigit(b.codeUnitAt(j))) {
        j++;
      }
      final aNum = _slice(a, aStart, i);
      final bNum = _slice(b, bStart, j);
      final byLength = _significant(aNum).compareTo(_significant(bNum));
      if (byLength != 0) return byLength;
      final byText = _stripZeros(aNum).compareTo(_stripZeros(bNum));
      if (byText != 0) return byText;
      continue;
    }
    final unit = a.codeUnitAt(i).compareTo(b.codeUnitAt(j));
    if (unit != 0) return unit;
    i++;
    j++;
  }
  return (a.length - i).compareTo(b.length - j);
}

int _significant(String number) {
  var index = 0;
  while (index < number.length - 1 && number.codeUnitAt(index) == 0x30) {
    index++;
  }
  return number.length - index;
}

String _stripZeros(String number) {
  var index = 0;
  while (index < number.length - 1 && number.codeUnitAt(index) == 0x30) {
    index++;
  }
  return _slice(number, index, number.length);
}

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

int _nameWidth(_Ref row, {required bool remoteBonus}) {
  if (row.detached) return row.description.length;
  final short = _lstrip(row.refname, 2);
  if (remoteBonus && row.refname.startsWith('refs/remotes/')) {
    return short.length + 'remotes/'.length;
  }
  return short.length;
}

/// Формат по умолчанию как у git 2.53.
///
/// У локальной ветки в `% (else)` два пробела: так собран бинарник Debian,
/// а не один пробел из опубликованного `branch.c`. У remote-строки те же
/// два пробела перед `remotes/`. Цвет локальной ветки пустой, но сброс
/// `\x1b[m` после имени всё равно пишется, когда цвет включён.
String _defaultFormat({
  required bool color,
  required int verbose,
  required int abbrev,
  required int maxWidth,
  required String remotePrefix,
}) {
  final current = color ? '\x1b[32m' : '';
  final worktree = color ? '\x1b[36m' : '';
  final remote = color ? '\x1b[31m' : '';
  final upstream = color ? '\x1b[34m' : '';
  final reset = color ? '\x1b[m' : '';
  final localHead =
      '%(if)%(HEAD)%(then)* $current%(else)%(if)%(worktreepath)%(then)+ $worktree%(else)  %(end)%(end)';
  final remoteHead = '  $remote';
  final object = abbrev <= 0
      ? '%(objectname)'
      : abbrev == 7
      ? '%(objectname:short)'
      : '%(objectname:short=$abbrev)';
  final localBody = verbose == 0
      ? '%(refname:lstrip=2)$reset%(if)%(symref)%(then) -> %(symref:short)%(end)'
      : '%(align:$maxWidth,left)%(refname:lstrip=2)%(end)$reset $object '
            '${verbose > 1 ? '%(if:notequals=*)%(HEAD)%(then)%(if)%(worktreepath)%(then)($worktree%(worktreepath)$reset) %(end)%(end)%(if)%(upstream)%(then)[$upstream%(upstream:short)$reset%(if)%(upstream:track)%(then): %(upstream:track,nobracket)%(end)] %(end)%(contents:subject)' : '%(if)%(upstream:track)%(then)%(upstream:track) %(end)%(contents:subject)'}';
  final remoteBody = verbose == 0
      ? '$remotePrefix%(refname:lstrip=2)$reset%(if)%(symref)%(then) -> %(symref:short)%(end)'
      : '%(align:$maxWidth,left)$remotePrefix%(refname:lstrip=2)%(end)$reset'
            '%(if)%(symref)%(then) -> %(symref:short)%(else) $object %(contents:subject)%(end)';
  return '%(if:notequals=refs/remotes)%(refname:rstrip=-2)%(then)$localHead$localBody%(else)$remoteHead$remoteBody%(end)';
}

String _render(
  String format,
  _Ref row, {
  required int abbrev,
  required _Reach reach,
}) {
  final stack = <_Frame>[_Frame.root()];
  final units = format.codeUnits;
  var index = 0;
  while (index < units.length) {
    if (units[index] == 0x25 && index + 1 < units.length) {
      final next = units[index + 1];
      if (next == 0x25) {
        stack.last.buf.write('%');
        index += 2;
        continue;
      }
      if (next == 0x6e) {
        stack.last.buf.write('\n');
        index += 2;
        continue;
      }
      if (next == 0x28) {
        final close = _close(units, index + 2);
        final body = String.fromCharCodes(units.getRange(index + 2, close));
        _atom(body, stack, row, abbrev: abbrev, reach: reach);
        index = close + 1;
        continue;
      }
    }
    stack.last.buf.writeCharCode(units[index]);
    index++;
  }
  if (stack.length != 1) {
    throw const GitUsage('fatal: format: %(end) atom missing\n', exitCode: 128);
  }
  return stack.single.buf.toString();
}

int _close(List<int> units, int start) {
  var depth = 1;
  for (var index = start; index < units.length; index++) {
    if (units[index] == 0x28) depth++;
    if (units[index] == 0x29) {
      depth--;
      if (depth == 0) return index;
    }
  }
  throw const GitUsage('fatal: format: unterminated atom\n', exitCode: 128);
}
