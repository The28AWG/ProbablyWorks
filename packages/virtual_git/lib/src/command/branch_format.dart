part of '../git_branch_command.dart';

/// Формат `--format` и модели строк списка.
void _atom(
  String body,
  List<_Frame> stack,
  _Ref row, {
  required int abbrev,
  required _Reach reach,
}) {
  final colon = body.indexOf(':');
  final name = colon < 0 ? body : _slice(body, 0, colon);
  final arg = colon < 0 ? null : _slice(body, colon + 1, body.length);
  switch (name) {
    case 'if':
      stack.add(_Frame.condition(_ifSpec(arg)));
    case 'then':
      final frame = stack.last;
      final spec = frame.spec;
      if (frame.kind != _Kind.condition || spec == null || spec.sawThen) {
        throw const GitUsage(
          'fatal: format: %(then) atom missing\n',
          exitCode: 128,
        );
      }
      spec.sawThen = true;
      spec.satisfied = _satisfied(frame.buf.toString(), spec);
      frame.buf.clear();
    case 'else':
      final frame = stack.last;
      final spec = frame.spec;
      if (spec == null || !spec.sawThen || spec.sawElse) {
        throw const GitUsage(
          'fatal: format: %(else) atom missing\n',
          exitCode: 128,
        );
      }
      spec.sawElse = true;
      stack.add(_Frame.otherwise(spec));
    case 'end':
      _end(stack);
    case 'align':
      stack.add(_Frame.align(_align(arg)));
    default:
      stack.last.buf.write(
        _value(name, arg, row, abbrev: abbrev, reach: reach),
      );
  }
}

void _end(List<_Frame> stack) {
  if (stack.length < 2) {
    throw const GitUsage('fatal: format: %(end) atom missing\n', exitCode: 128);
  }
  final top = stack.last;
  switch (top.kind) {
    case _Kind.root:
      throw const GitUsage(
        'fatal: format: %(end) atom missing\n',
        exitCode: 128,
      );
    case _Kind.align:
      final padded = _pad(top.buf.toString(), top.alignWidth, top.alignWhere);
      stack.removeLast();
      stack.last.buf.write(padded);
    case _Kind.otherwise:
      final spec = top.spec!;
      final alternative = top.buf.toString();
      stack.removeLast();
      final chosen = spec.satisfied ? stack.last.buf.toString() : alternative;
      stack.removeLast();
      stack.last.buf.write(chosen);
    case _Kind.condition:
      final spec = top.spec;
      if (spec == null || !spec.sawThen) {
        throw const GitUsage(
          'fatal: format: %(then) atom missing\n',
          exitCode: 128,
        );
      }
      final text = spec.satisfied ? top.buf.toString() : '';
      stack.removeLast();
      stack.last.buf.write(text);
  }
}

_If _ifSpec(String? arg) {
  if (arg == null || arg.isEmpty) return _If();
  if (arg.startsWith('equals=')) {
    return _If(equals: _slice(arg, 'equals='.length, arg.length));
  }
  if (arg.startsWith('notequals=')) {
    return _If(
      equals: _slice(arg, 'notequals='.length, arg.length),
      negate: true,
    );
  }
  throw GitUsage('fatal: unrecognized %(if) argument: $arg\n', exitCode: 128);
}

bool _satisfied(String text, _If spec) {
  final equals = spec.equals;
  if (equals == null) return !_blank(text);
  final same = text == equals;
  return spec.negate ? !same : same;
}

bool _blank(String text) {
  for (final unit in text.codeUnits) {
    if (unit != 0x20 &&
        unit != 0x09 &&
        unit != 0x0a &&
        unit != 0x0b &&
        unit != 0x0c &&
        unit != 0x0d) {
      return false;
    }
  }
  return true;
}

({int width, String where}) _align(String? arg) {
  final spec = arg ?? '';
  final comma = spec.indexOf(',');
  final widthText = comma < 0 ? spec : _slice(spec, 0, comma);
  final where = comma < 0 ? 'left' : _slice(spec, comma + 1, spec.length);
  final width = int.tryParse(widthText);
  if (width == null || width < 0) {
    throw GitUsage(
      'fatal: positive width expected align:$spec\n',
      exitCode: 128,
    );
  }
  return (width: width, where: where);
}

String _pad(String text, int width, String where) {
  if (text.length >= width) return text;
  final gap = width - text.length;
  return switch (where) {
    'right' => '${' ' * gap}$text',
    'middle' => '${' ' * (gap ~/ 2)}$text${' ' * (gap - gap ~/ 2)}',
    _ => '$text${' ' * gap}',
  };
}

String _value(
  String name,
  String? arg,
  _Ref row, {
  required int abbrev,
  required _Reach reach,
}) => switch (name) {
  'refname' => _refname(row, arg),
  'objectname' => _objectName(row, arg, abbrev),
  'HEAD' => row.current ? '*' : ' ',
  'symref' => _symref(row, arg),
  'upstream' => _upstreamAtom(row, arg, reach),
  'contents' => _contents(row, arg),
  'subject' => _contents(row, 'subject'),
  'authorname' => row.commit?.author.name ?? '',
  'authoremail' => row.commit?.author.email ?? '',
  'author' => _person(row.commit?.author),
  'committername' => row.commit?.committer.name ?? '',
  'committeremail' => row.commit?.committer.email ?? '',
  'committer' => _person(row.commit?.committer),
  'authordate' => _when(row.commit?.author, arg, 'authordate'),
  'committerdate' ||
  'creatordate' ||
  'taggerdate' => _when(row.commit?.committer, arg, name),
  'objecttype' => row.commit == null ? '' : 'commit',
  'worktreepath' => '',
  _ => throw GitUsage('fatal: unknown field name: $name\n', exitCode: 128),
};

String _person(GitCommitSignature? signature) =>
    signature == null ? '' : '${signature.name} <${signature.email}>';

String _refname(_Ref row, String? arg) {
  if (row.detached) return row.description;
  if (arg == null || arg.isEmpty) return row.refname;
  if (arg == 'short') return _matchName(row.refname);
  if (arg.startsWith('lstrip=')) {
    return _lstrip(row.refname, _number(arg, 'lstrip=', 'refname'));
  }
  if (arg.startsWith('rstrip=')) {
    return _rstrip(row.refname, _number(arg, 'rstrip=', 'refname'));
  }
  throw GitUsage(
    'fatal: unrecognized %(refname) argument: $arg\n',
    exitCode: 128,
  );
}

int _number(String arg, String prefix, String atom) {
  final raw = _slice(arg, prefix.length, arg.length);
  final number = int.tryParse(raw);
  if (number == null) {
    throw GitUsage(
      'fatal: unrecognized %($atom) argument: $arg\n',
      exitCode: 128,
    );
  }
  return number;
}

String _lstrip(String refname, int count) {
  final slashes = _slashes(refname);
  final remaining = count < 0 ? slashes + count + 1 : count;
  if (remaining <= 0) return refname;
  var seen = 0;
  for (var index = 0; index < refname.length; index++) {
    if (refname.codeUnitAt(index) == 0x2f) {
      seen++;
      if (seen == remaining) {
        return _slice(refname, index + 1, refname.length);
      }
    }
  }
  return '';
}

String _rstrip(String refname, int count) {
  final slashes = _slashes(refname);
  final remaining = count < 0 ? slashes + count + 1 : count;
  if (remaining <= 0) return refname;
  var end = refname.length;
  var seen = 0;
  for (var index = refname.length - 1; index >= 0; index--) {
    if (refname.codeUnitAt(index) == 0x2f) {
      seen++;
      if (seen == remaining) {
        end = index;
        break;
      }
    }
  }
  if (seen < remaining) return '';
  return _slice(refname, 0, end);
}

int _slashes(String text) {
  var count = 0;
  for (final unit in text.codeUnits) {
    if (unit == 0x2f) count++;
  }
  return count;
}

String _objectName(_Ref row, String? arg, int abbrev) {
  final hex = row.objectId.hex;
  if (arg == null || arg.isEmpty) return hex;
  if (arg == 'short') return _shortHex(hex, abbrev);
  if (arg.startsWith('short=')) {
    return _shortHex(hex, _number(arg, 'short=', 'objectname'));
  }
  throw GitUsage(
    'fatal: unrecognized %(objectname) argument: $arg\n',
    exitCode: 128,
  );
}

String _shortHex(String hex, int length) {
  if (length <= 0 || length >= hex.length) return hex;
  final shown = length < 4 ? 4 : length;
  if (shown >= hex.length) return hex;
  return _slice(hex, 0, shown);
}

String _symref(_Ref row, String? arg) {
  final target = row.symref;
  if (target == null) return '';
  if (arg == null || arg.isEmpty) return target;
  if (arg == 'short') return _matchName(target);
  throw GitUsage(
    'fatal: unrecognized %(symref) argument: $arg\n',
    exitCode: 128,
  );
}

String _contents(_Ref row, String? arg) {
  final message = row.commit?.message ?? '';
  final newline = message.indexOf('\n');
  final subject = newline < 0 ? message : _slice(message, 0, newline);
  if (arg == null || arg == 'subject') return subject;
  if (arg == 'body') {
    if (newline < 0) return '';
    var rest = _slice(message, newline + 1, message.length);
    if (rest.startsWith('\n')) rest = _slice(rest, 1, rest.length);
    return rest;
  }
  throw GitUsage(
    'fatal: unrecognized %(contents) argument: $arg\n',
    exitCode: 128,
  );
}

String _when(GitCommitSignature? signature, String? arg, String atom) {
  if (signature == null) return '';
  if (arg == null || arg.isEmpty) return _gitDate(signature);
  if (arg == 'unix') return '${signature.timestampSeconds}';
  final date = _wall(signature);
  if (arg == 'short') {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
  if (arg == 'iso' || arg == 'iso8601') {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}:'
        '${date.second.toString().padLeft(2, '0')} '
        '${signature.timezoneOffset}';
  }
  throw GitUsage(
    'fatal: unrecognized %($atom) argument: $arg\n',
    exitCode: 128,
  );
}

String _gitDate(GitCommitSignature signature) {
  final date = _wall(signature);
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${weekdays[date.weekday - 1]} ${months[date.month - 1]} '
      '${date.day.toString().padLeft(2, ' ')} '
      '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}:'
      '${date.second.toString().padLeft(2, '0')} '
      '${date.year} ${signature.timezoneOffset}';
}

DateTime _wall(GitCommitSignature signature) {
  final zoned = RegExp(r'^([+-])(\d\d)(\d\d)$')
      .firstMatch(signature.timezoneOffset);
  var seconds = signature.timestampSeconds;
  if (zoned != null) {
    final sign = zoned.group(1) == '-' ? -1 : 1;
    final shift =
        int.parse(zoned.group(2)!) * 3600 + int.parse(zoned.group(3)!) * 60;
    seconds += sign * shift;
  }
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

String _upstreamAtom(_Ref row, String? arg, _Reach reach) {
  final info = row.detached ? null : reach.tracking[row.refname];
  if (info == null) return '';
  if (arg == null || arg.isEmpty || arg == 'short') return info.label;
  if (arg == 'track') return info.track;
  if (arg == 'track,nobracket') return info.bareTrack;
  if (arg == 'trackshort') return info.trackShort;
  throw GitUsage(
    'fatal: unrecognized %(upstream) argument: $arg\n',
    exitCode: 128,
  );
}

String _layout(
  List<String> items, {
  required int width,
  required bool across,
  required bool dense,
}) {
  if (items.isEmpty) return '';
  final room = width < 1 ? 1 : width;
  var longest = 0;
  for (final item in items) {
    if (item.length > longest) longest = item.length;
  }
  const padding = 1;
  final cell = longest + padding;
  var cols = room ~/ cell;
  if (cols < 1) cols = 1;
  if (cols > items.length) cols = items.length;
  var rows = (items.length + cols - 1) ~/ cols;
  if (dense) {
    while (cols < items.length) {
      final nextCols = cols + 1;
      final nextRows = (items.length + nextCols - 1) ~/ nextCols;
      if (_denseWidth(items, nextCols, nextRows, across) > room) break;
      cols = nextCols;
      rows = nextRows;
    }
  }
  final buffer = StringBuffer();
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      final index = across ? y * cols + x : x * rows + y;
      if (index >= items.length) break;
      final item = items[index];
      buffer.write(item);
      final next = across ? y * cols + x + 1 : (x + 1) * rows + y;
      final last = x == cols - 1 || next >= items.length;
      if (!last) {
        final pad = dense
            ? _columnWidth(items, x, cols, rows, across) - item.length + padding
            : cell - item.length;
        if (pad > 0) buffer.write(' ' * pad);
      }
    }
    buffer.write('\n');
  }
  return buffer.toString();
}

int _denseWidth(List<String> items, int cols, int rows, bool across) {
  var total = 0;
  for (var column = 0; column < cols; column++) {
    total += _columnWidth(items, column, cols, rows, across);
    if (column + 1 < cols) total += 1;
  }
  return total;
}

int _columnWidth(
  List<String> items,
  int column,
  int cols,
  int rows,
  bool across,
) {
  var width = 0;
  for (var y = 0; y < rows; y++) {
    final index = across ? y * cols + column : column * rows + y;
    if (index >= items.length) continue;
    if (items[index].length > width) width = items[index].length;
  }
  return width;
}

int _termWidth(AppletIo io) {
  final raw = io.env['COLUMNS'];
  final number = raw == null ? 80 : int.tryParse(raw) ?? 80;
  return number <= 0 ? 80 : number;
}

Future<void> _rejectName(GitRepository repo, String name) async {
  if (_validBranch(name)) return;
  final hint = _adviceOff(await repo.configGet('advice.refSyntax'))
      ? ''
      : "hint: See 'git help check-ref-format'\n"
            'hint: Disable this message with "git config set advice.refSyntax false"\n';
  throw GitUsage(
    "fatal: '$name' is not a valid branch name\n$hint",
    exitCode: 128,
  );
}

bool _adviceOff(String? value) => switch (value?.toLowerCase()) {
  'false' || '0' || 'no' || 'off' => true,
  _ => false,
};

bool _validBranch(String name) {
  if (name.isEmpty || name == '@' || name == 'HEAD') return false;
  if (name.startsWith('/') || name.endsWith('/') || name.contains('//')) {
    return false;
  }
  if (name.contains('..') || name.contains('@{')) return false;
  if (name.endsWith('.lock') || name.endsWith('.')) return false;
  for (final unit in name.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return false;
    if (const {0x20, 0x7e, 0x5e, 0x3a, 0x3f, 0x2a, 0x5b, 0x5c}.contains(unit)) {
      return false;
    }
  }
  for (final part in name.split('/')) {
    if (part.isEmpty ||
        part.startsWith('.') ||
        part.endsWith('.lock') ||
        part.endsWith('.')) {
      return false;
    }
  }
  return true;
}

String? _branchOf(String? reference) {
  if (reference == null || !reference.startsWith('refs/heads/')) return null;
  return _slice(reference, 'refs/heads/'.length, reference.length);
}

Future<_Resolved?> _resolveBranch(GitRepository repo, String name) async {
  final candidates = <String>[
    if (name.startsWith('refs/')) name,
    'refs/remotes/$name',
    'refs/heads/$name',
  ];
  for (final candidate in candidates) {
    if (await repo.readReference(candidate) == null) continue;
    if (await repo.resolveReferenceObjectId(candidate) == null) continue;
    return _Resolved(candidate);
  }
  return null;
}

Future<_Upstream> _upstreamTarget(
  GitRepository repo,
  String name, {
  required bool explicit,
}) async {
  final resolved = await _resolveBranch(repo, name);
  if (resolved == null) {
    if (await repo.revParse(name) != null && explicit) {
      throw GitUsage(
        'fatal: cannot set up tracking information; starting point '
        "'$name' is not a branch\n",
        exitCode: 128,
      );
    }
    final hint = _adviceOff(await repo.configGet('advice.setUpstreamFailure'))
        ? '\n'
        : '\nhint:\n'
              'hint: If you are planning on basing your work on an upstream\n'
              'hint: branch that already exists at the remote, you may need to\n'
              'hint: run "git fetch" to retrieve it.\n'
              'hint:\n'
              'hint: If you are planning to push out a new local branch that\n'
              'hint: will track its remote counterpart, you may want to use\n'
              'hint: "git push -u" to set the upstream config as you push.\n'
              'hint: Disable this message with "git config set advice.setUpstreamFailure false"\n';
    throw GitUsage(
      "fatal: the requested upstream branch '$name' does not exist$hint",
      exitCode: 128,
    );
  }
  if (resolved.reference.startsWith('refs/heads/')) {
    final short = _branchOf(resolved.reference)!;
    return _Upstream(remote: '.', merge: resolved.reference, label: short);
  }
  final short = _slice(
    resolved.reference,
    'refs/remotes/'.length,
    resolved.reference.length,
  );
  final slash = short.indexOf('/');
  if (slash <= 0) {
    throw GitUsage(
      "fatal: cannot set up tracking information; starting point '$name' is not a branch\n",
      exitCode: 128,
    );
  }
  final remote = _slice(short, 0, slash);
  if (await repo.configGet('remote.$remote.url') == null) {
    throw GitUsage(
      "fatal: cannot set up tracking information; starting point '$name' is not a branch\n",
      exitCode: 128,
    );
  }
  final branch = _slice(short, slash + 1, short.length);
  return _Upstream(remote: remote, merge: 'refs/heads/$branch', label: short);
}

String _upstreamLabel(String remote, String merge) {
  final branch = merge.startsWith('refs/heads/')
      ? _slice(merge, 'refs/heads/'.length, merge.length)
      : merge;
  if (remote == '.') return branch;
  return '$remote/$branch';
}

bool _wild(String pattern, String text, {required bool ignoreCase}) {
  final left = ignoreCase ? pattern.toLowerCase() : pattern;
  final right = ignoreCase ? text.toLowerCase() : text;
  return _wildAt(left, 0, right, 0);
}

bool _wildAt(String pattern, int patternIndex, String text, int textIndex) {
  var pi = patternIndex;
  var ti = textIndex;
  while (pi < pattern.length) {
    final unit = pattern.codeUnitAt(pi);
    if (unit == 0x2a) {
      while (pi < pattern.length && pattern.codeUnitAt(pi) == 0x2a) {
        pi++;
      }
      if (pi == pattern.length) return true;
      for (var index = ti; index <= text.length; index++) {
        if (_wildAt(pattern, pi, text, index)) return true;
      }
      return false;
    }
    if (ti >= text.length) return false;
    if (unit != 0x3f && unit != text.codeUnitAt(ti)) return false;
    pi++;
    ti++;
  }
  return ti == text.length;
}

String _slice(String text, int start, int end) =>
    String.fromCharCodes(text.codeUnits.getRange(start, end));

enum _Track { auto, direct, inherit, no }

enum _Col { off, down, across, plain }

final class _Columns {
  const _Columns(this.mode, {this.dense = false});

  const _Columns.off() : mode = _Col.off, dense = false;

  final _Col mode;
  final bool dense;
}

final class _Upstream {
  const _Upstream({
    required this.remote,
    required this.merge,
    required this.label,
  });

  final String remote;
  final String merge;
  final String label;
}

final class _Resolved {
  const _Resolved(this.reference);

  final String reference;
}

final class _Ref {
  _Ref({
    required this.refname,
    required this.objectId,
    required this.commit,
    required this.detached,
    required this.current,
    required this.symref,
    required this.description,
  });

  final String refname;
  final GitObjectId objectId;
  final GitCommit? commit;
  final bool detached;
  bool current;
  final String? symref;
  final String description;
}

/// Кэш предков и уже посчитанный текст upstream для атомов формата.
final class _Reach {
  _Reach(this.repo);

  final GitRepository repo;
  final Map<String, Set<String>> _sets = {};
  final Map<String, _TrackText?> tracking = {};

  Future<Set<String>> of(String hex) async {
    final cached = _sets[hex];
    if (cached != null) return cached;
    final set = <String>{
      for (final entry in await repo.log(hex)) entry.objectId.hex,
    };
    _sets[hex] = set;
    return set;
  }

  Future<_TrackText?> describe(_Ref row) async {
    if (tracking.containsKey(row.refname)) return tracking[row.refname];
    final text = await _describe(row);
    tracking[row.refname] = text;
    return text;
  }

  Future<_TrackText?> _describe(_Ref row) async {
    if (row.detached || !row.refname.startsWith('refs/heads/')) return null;
    final name = _branchOf(row.refname);
    if (name == null) return null;
    final remote = await repo.configGet('branch.$name.remote');
    final merge = await repo.configGet('branch.$name.merge');
    if (remote == null || merge == null || remote.isEmpty || merge.isEmpty) {
      return null;
    }
    final label = _upstreamLabel(remote, merge);
    final upstream = remote == '.'
        ? merge
        : 'refs/remotes/$remote/${label.startsWith('$remote/') ? _slice(label, remote.length + 1, label.length) : label}';
    final id = await repo.revParse(upstream);
    if (id == null) {
      return _TrackText(label: label, ahead: 0, behind: 0, gone: true);
    }
    final local = await of(row.objectId.hex);
    final base = await of(id.hex);
    var ahead = 0;
    var behind = 0;
    for (final item in local) {
      if (!base.contains(item)) ahead++;
    }
    for (final item in base) {
      if (!local.contains(item)) behind++;
    }
    return _TrackText(label: label, ahead: ahead, behind: behind, gone: false);
  }
}

final class _TrackText {
  const _TrackText({
    required this.label,
    required this.ahead,
    required this.behind,
    required this.gone,
  });

  final String label;
  final int ahead;
  final int behind;
  final bool gone;

  String get bareTrack {
    if (gone) return 'gone';
    if (ahead == 0 && behind == 0) return '';
    if (behind == 0) return 'ahead $ahead';
    if (ahead == 0) return 'behind $behind';
    return 'ahead $ahead, behind $behind';
  }

  String get track {
    final bare = bareTrack;
    if (bare.isEmpty) return '';
    return '[$bare]';
  }

  String get trackShort {
    if (gone) return '';
    if (ahead == 0 && behind == 0) return '=';
    if (ahead > 0 && behind > 0) return '<>';
    if (ahead > 0) return '>';
    return '<';
  }
}

enum _Kind { root, condition, otherwise, align }

final class _If {
  _If({this.equals, this.negate = false});

  final String? equals;
  final bool negate;
  var sawThen = false;
  var sawElse = false;
  var satisfied = false;
}

final class _Frame {
  _Frame.root() : kind = _Kind.root;

  _Frame.condition(this.spec) : kind = _Kind.condition;

  _Frame.otherwise(this.spec) : kind = _Kind.otherwise;

  _Frame.align(({int width, String where}) align)
    : kind = _Kind.align,
      alignWidth = align.width,
      alignWhere = align.where;

  final _Kind kind;
  final buffer = StringBuffer();
  StringBuffer get buf => buffer;
  _If? spec;
  var alignWidth = 0;
  var alignWhere = 'left';
}
