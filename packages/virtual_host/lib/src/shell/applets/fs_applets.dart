import 'dart:async';

import 'package:virtual_host/src/shell/applets/applet.dart';
import 'package:virtual_host/src/shell/applets/applet_args.dart';
import 'package:virtual_host/src/shell/shell_errors.dart';
import 'package:virtual_host/src/shell/shell_io.dart';
import 'package:virtual_host/src/vfs_access.dart';
import 'package:virtual_host/src/vfs_listing.dart';
import 'package:virtual_host/src/vfs_store.dart';
import 'package:virtual_host/src/virtual_fs.dart';

/// Апплеты файловой системы: каталоги, файлы, метаданные и обход. Всё идёт через [AppletIo.fs], поэтому
/// соблюдаются квоты, лимиты размера и правила симлинков VFS.
final List<Applet> fsApplets = [
  const _Ls(),
  const _Mkdir(),
  const _Touch(),
  const _Rm(),
  const _Cp(),
  const _Mv(),
  const _Stat(),
  const _Find(),
];

/// `ls [-aAlRd1] [PATH...]`: содержимое каталогов и метаданные файлов. Вывод по одной записи в строке,
/// как у GNU ls при выводе не в терминал. Сортировка по имени (байтовый порядок, локаль C).
final class _Ls implements Applet {
  const _Ls();

  @override
  String get name => 'ls';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'aAlRd1');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final long = parsed.has('l');
    final operands = parsed.operands.isEmpty ? ['.'] : parsed.operands;
    final files = <({String name, VfsNode node})>[];
    final dirs = <String>[];
    var status = 0;
    for (final operand in operands) {
      final node = await _lstatOperand(
        io,
        operand,
        dereferenceDir: !parsed.has('d'),
      );
      if (node == null) {
        io.stderr.writeText(
          "$name: cannot access '$operand': No such file or directory\n",
        );
        status = 2;
      } else if (node.kind == VfsNodeKind.dir && !parsed.has('d')) {
        dirs.add(operand);
      } else {
        files.add((name: operand, node: node));
      }
    }
    final options = _ListOptions(
      showDots: parsed.has('a'),
      showHidden: parsed.has('a') || parsed.has('A'),
      long: long,
      recursive: parsed.has('R'),
    );
    if (files.isNotEmpty) {
      files.sort((a, b) => a.name.compareTo(b.name));
      _writeEntries(io, files, options, total: false);
    }
    final showHeaders = operands.length > 1 || options.recursive;
    for (var index = 0; index < dirs.length; index++) {
      if (index > 0 || files.isNotEmpty) {
        io.stdout.writeText('\n');
      }
      final code = await _listDir(
        io,
        dirs[index],
        options: options,
        showHeader: showHeaders,
      );
      if (code != 0) {
        status = code;
      }
    }
    return status;
  }

  /// Листинг одного каталога. [showHeader] — заголовок `путь:` для нескольких операндов и `-R`.
  /// Возвращает 2, если каталог не открылся.
  Future<int> _listDir(
    AppletIo io,
    String path, {
    required _ListOptions options,
    required bool showHeader,
  }) async {
    final List<VfsNode> children;
    try {
      children = await io.fs.list(path, cwd: io.cwd);
    } on VfsException catch (e) {
      io.stderr.writeText(
        "$name: cannot open directory '$path': ${e.message}\n",
      );
      return 2;
    }
    final entries = <({String name, VfsNode node})>[];
    final dir = await io.fs.stat(path, cwd: io.cwd);
    if (options.showDots && dir != null) {
      entries.add((name: '.', node: dir));
      final parent = await io.fs.stat('$path/..', cwd: io.cwd);
      if (parent != null) entries.add((name: '..', node: parent));
    }
    final sorted = [...children]..sort((a, b) => a.name.compareTo(b.name));
    for (final node in sorted) {
      if (!options.showHidden && node.name.startsWith('.')) continue;
      entries.add((name: node.name, node: node));
    }
    if (showHeader) io.stdout.writeText('$path:\n');
    _writeEntries(io, entries, options, total: true);
    if (options.recursive) {
      for (final entry in entries) {
        if (entry.node.kind != VfsNodeKind.dir ||
            entry.name == '.' ||
            entry.name == '..') {
          continue;
        }
        io.stdout.writeText('\n');
        await _listDir(
          io,
          path == '/' ? '/${entry.name}' : '$path/${entry.name}',
          options: options,
          showHeader: true,
        );
      }
    }
    return 0;
  }

  /// Печатает записи. В длинном формате первой строкой идёт `total` (в KiB), как у GNU.
  static void _writeEntries(
    AppletIo io,
    List<({String name, VfsNode node})> entries,
    _ListOptions options, {
    required bool total,
  }) {
    if (!options.long) {
      for (final entry in entries) {
        io.stdout.writeText('${entry.name}\n');
      }
      return;
    }
    if (total) {
      var blocks = 0;
      for (final entry in entries) {
        blocks += VfsListing.blocksOf(entry.node);
      }
      io.stdout.writeText('total $blocks\n');
    }
    var width = 1;
    for (final entry in entries) {
      final size = VfsListing.sizeOf(entry.node).toString().length;
      if (size > width) width = size;
    }
    for (final entry in entries) {
      io.stdout.writeText(
        '${VfsListing.longLine(entry.node, entry.name, width: width, now: io.fs.now(), owner: vfsAccountName(entry.node.uid, io.profile.user))}\n',
      );
    }
  }

  /// Метаданные операнда. Симлинк на каталог раскрывается, как у GNU ls для аргументов командной строки;
  /// остальные симлинки показываются сами (`-l` покажет `имя -> цель`). С `-d` каталог не раскрывается.
  static Future<VfsNode?> _lstatOperand(
    AppletIo io,
    String operand, {
    required bool dereferenceDir,
  }) async {
    final link = await io.fs.stat(operand, cwd: io.cwd, followLast: false);
    if (link == null) return null;
    if (link.kind != VfsNodeKind.symlink || !dereferenceDir) return link;
    final target = await io.fs.stat(operand, cwd: io.cwd);
    return target?.kind == VfsNodeKind.dir ? target : link;
  }
}

/// Параметры вывода `ls`.
final class _ListOptions {
  const _ListOptions({
    required this.showDots,
    required this.showHidden,
    required this.long,
    required this.recursive,
  });

  /// `-a`: показать `.` и `..`.
  final bool showDots;

  /// Показать записи с точкой в начале: `-a` или `-A`.
  final bool showHidden;

  /// `-l`: длинный формат с правами, владельцем, размером и датой.
  final bool long;

  /// `-R`: рекурсивный обход подкаталогов.
  final bool recursive;
}

/// `mkdir [-p] [-v] DIR...`: создаёт каталоги. `-p` создаёт предков и не падает на существующем каталоге.
final class _Mkdir implements Applet {
  const _Mkdir();

  @override
  String get name => 'mkdir';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'pv');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.isEmpty) return usageError(io, name, 'missing operand');
    var status = 0;
    for (final operand in parsed.operands) {
      try {
        await io.fs.mkdir(operand, cwd: io.cwd, recursive: parsed.has('p'));
        if (parsed.has('v')) {
          io.stdout.writeText("$name: created directory '$operand'\n");
        }
      } on VfsException catch (e) {
        io.stderr.writeText(
          "$name: cannot create directory '$operand': ${e.message}\n",
        );
        status = 1;
      }
    }
    return status;
  }
}

/// `touch [-c] FILE...`: создаёт пустой файл или обновляет время изменения. `-c` не создаёт новых файлов.
final class _Touch implements Applet {
  const _Touch();

  @override
  String get name => 'touch';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'c');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.isEmpty) {
      return usageError(io, name, 'missing file operand');
    }
    var status = 0;
    for (final operand in parsed.operands) {
      try {
        if (parsed.has('c') && await io.fs.stat(operand, cwd: io.cwd) == null) {
          continue;
        }
        await io.fs.touch(operand, cwd: io.cwd);
      } on VfsException catch (e) {
        io.stderr.writeText("$name: cannot touch '$operand': ${e.message}\n");
        status = 1;
      }
    }
    return status;
  }
}

/// `rm [-rRf] FILE...`: удаляет файлы; каталоги — с `-r`. `-f` не сообщает о несуществующих и не падает.
final class _Rm implements Applet {
  const _Rm();

  @override
  String get name => 'rm';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'rRf');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.isEmpty) {
      if (parsed.has('f')) return 0;
      return usageError(io, name, 'missing operand');
    }
    var status = 0;
    final recursive = parsed.has('r') || parsed.has('R');
    for (final operand in parsed.operands) {
      try {
        if (parsed.has('f') &&
            await io.fs.stat(operand, cwd: io.cwd, followLast: false) == null) {
          continue;
        }
        await io.fs.remove(operand, cwd: io.cwd, recursive: recursive);
      } on VfsException catch (e) {
        io.stderr.writeText("$name: cannot remove '$operand': ${e.message}\n");
        status = 1;
      }
    }
    return status;
  }
}

/// `cp [-rR] SOURCE... DEST`: копирует файлы и каталоги. Несколько источников или существующий каталог
/// в роли DEST — копирование внутрь каталога. Симлинк без `-r` копируется по цели, как у GNU cp.
final class _Cp implements Applet {
  const _Cp();

  @override
  String get name => 'cp';

  @override
  Future<int> run(AppletIo io, List<String> args) {
    final parsed = parseArgs(args, flags: 'rR');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.isEmpty) {
      return usageError(io, name, 'missing file operand');
    }
    if (parsed.operands.length < 2) {
      return usageError(
        io,
        name,
        "missing destination file operand after '${parsed.operands.first}'",
      );
    }
    return _transfer(
      io,
      name,
      parsed.operands,
      recursive: parsed.has('r') || parsed.has('R'),
      move: false,
    );
  }
}

/// `mv SOURCE... DEST`: переименовывает или переносит. Правила назначения те же, что у `cp`.
final class _Mv implements Applet {
  const _Mv();

  @override
  String get name => 'mv';

  @override
  Future<int> run(AppletIo io, List<String> args) {
    final parsed = parseArgs(args, flags: 'f');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.isEmpty) {
      return usageError(io, name, 'missing file operand');
    }
    if (parsed.operands.length < 2) {
      return usageError(
        io,
        name,
        "missing destination file operand after '${parsed.operands.first}'",
      );
    }
    return _transfer(io, name, parsed.operands, recursive: true, move: true);
  }
}

/// Общая часть `cp` и `mv`: разбирает назначение и выполняет операцию для каждого источника.
Future<int> _transfer(
  AppletIo io,
  String name,
  List<String> operands, {
  required bool recursive,
  required bool move,
}) async {
  final dest = operands.last;
  final sources = operands.sublist(0, operands.length - 1);
  final destNode = await io.fs.stat(dest, cwd: io.cwd);
  final destIsDir = destNode?.kind == VfsNodeKind.dir;
  if (sources.length > 1 && !destIsDir) {
    io.stderr.writeText("$name: target '$dest' is not a directory\n");
    return 1;
  }
  var status = 0;
  for (final source in sources) {
    final node = await io.fs.stat(source, cwd: io.cwd, followLast: false);
    if (node == null) {
      io.stderr.writeText(
        "$name: cannot stat '$source': No such file or directory\n",
      );
      status = 1;
      continue;
    }
    if (node.kind == VfsNodeKind.dir && !move && !recursive) {
      io.stderr.writeText(
        "$name: -r not specified; omitting directory '$source'\n",
      );
      status = 1;
      continue;
    }
    final target = destIsDir ? '${trimSlashes(dest)}/${baseOf(source)}' : dest;
    try {
      if (move) {
        await io.fs.rename(source, target, cwd: io.cwd);
      } else {
        // Без -r симлинк копируется по цели: это поведение GNU cp по умолчанию.
        final from = !recursive && node.kind == VfsNodeKind.symlink
            ? await io.fs.realpath(source, cwd: io.cwd)
            : source;
        await io.fs.copy(from, target, cwd: io.cwd, recursive: recursive);
      }
    } on VfsException catch (e) {
      final what = move
          ? "cannot move '$source' to '$target'"
          : "cannot create ${node.kind == VfsNodeKind.dir ? 'directory' : 'regular file'} '$target'";
      io.stderr.writeText('$name: $what: ${e.message}\n');
      status = 1;
    }
  }
  return status;
}

/// `stat [-c FORMAT] FILE...`. Без `-c` печатает блок в стиле GNU, без номеров Device и Inode:
/// у виртуальной ФС их нет. Форматы: `%n %s %b %a %A %F %u %g %U %G %Y %y %x %w %%`.
final class _Stat implements Applet {
  const _Stat();

  @override
  String get name => 'stat';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, valued: 'c');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.isEmpty) return usageError(io, name, 'missing operand');
    final format = parsed.value('c');
    var status = 0;
    for (final operand in parsed.operands) {
      final node = await io.fs.stat(operand, cwd: io.cwd, followLast: false);
      if (node == null) {
        io.stderr.writeText(
          "$name: cannot statx '$operand': No such file or directory\n",
        );
        status = 1;
        continue;
      }
      final line = format == null
          ? _defaultBlock(io, operand, node)
          : '${_formatNode(io, operand, node, format)}\n';
      io.stdout.writeText(line);
    }
    return status;
  }

  static String _defaultBlock(AppletIo io, String operand, VfsNode node) {
    final user = vfsAccountName(node.uid, io.profile.user);
    final group = vfsAccountName(node.gid, io.profile.user);
    final mode = node.mode & 0xfff;
    final octal = mode.toRadixString(8).padLeft(4, '0');
    final perms = VfsListing.permissions(node);
    final blocks = VfsListing.blocksOf(node);
    final ioBlock = 4096;
    final size = VfsListing.sizeOf(node);
    return [
      '  File: $operand',
      'Size: $size\tBlocks: $blocks\tIO Block: $ioBlock\t${_typeName(node)}',
      'Access: ($octal/$perms)  Uid: (${node.uid}/$user)   Gid: (${node.gid}/$group)',
      'Access: ${_timestamp(node.mtime)}',
      'Modify: ${_timestamp(node.mtime)}',
      'Change: ${_timestamp(node.mtime)}',
      ' Birth: -',
      '',
    ].join('\n');
  }

  static String _formatNode(
    AppletIo io,
    String operand,
    VfsNode node,
    String format,
  ) {
    final out = StringBuffer();
    for (var i = 0; i < format.length; i++) {
      final ch = format[i];
      if (ch != '%' || i + 1 >= format.length) {
        out.write(ch);
        continue;
      }
      final spec = format[++i];
      out.write(switch (spec) {
        '%' => '%',
        'n' => operand,
        's' => VfsListing.sizeOf(node),
        'b' => VfsListing.blocksOf(node),
        'a' => (node.mode & 0xfff).toRadixString(8),
        'A' => VfsListing.permissions(node),
        'F' => _typeName(node),
        'u' => node.uid,
        'g' => node.gid,
        'U' => vfsAccountName(node.uid, io.profile.user),
        'G' => vfsAccountName(node.gid, io.profile.user),
        'Y' || 'X' || 'Z' => node.mtime,
        'y' || 'x' || 'z' => _timestamp(node.mtime),
        'w' => '-',
        _ => '%$spec',
      });
    }
    return out.toString();
  }

  static String _typeName(VfsNode node) => switch (node.kind) {
    VfsNodeKind.dir => 'directory',
    VfsNodeKind.symlink => 'symbolic link',
    VfsNodeKind.file => node.size == 0 ? 'regular empty file' : 'regular file',
  };

  /// Время как у GNU stat: `2026-11-05 12:00:00.000000000 +0000` (UTC).
  static String _timestamp(int mtime) {
    final t = DateTime.fromMillisecondsSinceEpoch(mtime * 1000, isUtc: true);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.000000000 +0000';
  }
}

/// `find [PATH...] [-maxdepth N] [-mindepth N] [EXPR]`. Предикаты: `-name`, `-iname`, `-path`, `-ipath`,
/// `-type f|d|l`, `-empty`; действия: `-print`, `-print0`. Операторы: `!`, `( )`, `-a`, `-o`, неявное `-a`.
/// Обход не переходит по симлинкам, порядок — по имени. Лимит записей — [VirtualLimits.maxWalkEntries].
final class _Find implements Applet {
  const _Find();

  @override
  String get name => 'find';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    var index = 0;
    final roots = <String>[];
    while (index < args.length && !_startsExpression(args[index])) {
      roots.add(args[index++]);
    }
    if (roots.isEmpty) roots.add('.');
    var minDepth = 0;
    var maxDepth = 1 << 30;
    final expression = <String>[];
    while (index < args.length) {
      final token = args[index++];
      if (token == '-maxdepth' || token == '-mindepth') {
        if (index >= args.length) {
          return usageError(io, name, "missing argument to '$token'");
        }
        final depth = int.tryParse(args[index++]);
        if (depth == null || depth < 0) {
          return usageError(io, name, "invalid argument to '$token'");
        }
        if (token == '-maxdepth') {
          maxDepth = depth;
        } else {
          minDepth = depth;
        }
        continue;
      }
      expression.add(token);
    }
    final _Node root;
    try {
      root = _ExpressionParser(expression).parse();
    } on _FindSyntax catch (e) {
      io.stderr.writeText('$name: ${e.message}\n');
      return 1;
    }
    final walk = _Walk(io, root, minDepth: minDepth, maxDepth: maxDepth);
    var status = 0;
    for (final start in roots) {
      if (!await walk.start(start)) status = 1;
    }
    return status;
  }

  static bool _startsExpression(String token) =>
      (token.startsWith('-') && token != '-') || token == '(' || token == '!';
}

/// Выражение `find` после разбора.
sealed class _Node {
  const _Node();
}

/// Проверка кандидата. Асинхронная, потому что `-empty` читает каталог.
final class _Predicate extends _Node {
  const _Predicate(this.test);

  final FutureOr<bool> Function(_Candidate candidate) test;
}

/// Действие `-print` (или `-print0` с NUL-разделителем). Всегда истинно.
final class _Print extends _Node {
  const _Print({required this.zero});

  final bool zero;
}

final class _Not extends _Node {
  const _Not(this.inner);

  final _Node inner;
}

final class _And extends _Node {
  const _And(this.left, this.right);

  final _Node left;
  final _Node right;
}

final class _Or extends _Node {
  const _Or(this.left, this.right);

  final _Node left;
  final _Node right;
}

/// Выражение без предикатов: истинно всегда (`find` без аргументов выводит всё).
final class _Always extends _Node {
  const _Always();
}

/// Ошибка разбора выражения `find`: неизвестный предикат, незакрытая скобка и т. п.
final class _FindSyntax implements Exception {
  const _FindSyntax(this.message);

  final String message;
}

/// Кандидат для проверки: путь как его показываем, имя для `-name`, узел и ФС для `-empty`.
final class _Candidate {
  const _Candidate({
    required this.display,
    required this.name,
    required this.node,
    required this.fs,
  });

  final String display;
  final String name;
  final VfsNode node;
  final VirtualFs fs;
}

/// Рекурсивный спуск по выражению `find`. Глубина считается от точки старта.
final class _Walk {
  _Walk(this.io, this.root, {required this.minDepth, required this.maxDepth});

  final AppletIo io;
  final _Node root;
  final int minDepth;
  final int maxDepth;
  int _visited = 0;

  /// Обходит один стартовый путь. Возвращает false, если путь не существует.
  Future<bool> start(String path) async {
    final node = await io.fs.stat(path, cwd: io.cwd, followLast: false);
    if (node == null) {
      io.stderr.writeText("find: '$path': No such file or directory\n");
      return false;
    }
    await _visit(path, node, 0);
    return true;
  }

  Future<void> _visit(String display, VfsNode node, int depth) async {
    if (++_visited > io.fs.limits.maxWalkEntries) {
      throw ShellLimitExceeded(
        'find: more than ${io.fs.limits.maxWalkEntries} entries',
      );
    }
    if (depth >= minDepth) {
      final candidate = _Candidate(
        display: display,
        name: baseOf(display),
        node: node,
        fs: io.fs,
      );
      await _eval(root, candidate);
    }
    if (node.kind != VfsNodeKind.dir || depth >= maxDepth) return;
    final children = await io.fs.list(node.path);
    children.sort((a, b) => a.name.compareTo(b.name));
    for (final child in children) {
      final childDisplay = display.endsWith('/')
          ? '$display${child.name}'
          : '$display/${child.name}';
      await _visit(childDisplay, child, depth + 1);
    }
  }

  Future<bool> _eval(_Node node, _Candidate candidate) async => switch (node) {
    _Always() => true,
    _Predicate(:final test) => await test(candidate),
    _Not(:final inner) => !await _eval(inner, candidate),
    _And(:final left, :final right) =>
      await _eval(left, candidate) && await _eval(right, candidate),
    _Or(:final left, :final right) =>
      await _eval(left, candidate) || await _eval(right, candidate),
    _Print(:final zero) => _print(candidate, zero: zero),
  };

  bool _print(_Candidate candidate, {required bool zero}) {
    io.stdout.writeText(
      zero ? '${candidate.display}\x00' : '${candidate.display}\n',
    );
    return true;
  }
}

/// Разбор выражения `find` рекурсивным спуском: `or := and ('-o' and)*`, `and := unary ('-a'? unary)*`,
/// `unary := '!' unary | '(' or ')' | primary`. Если в выражении нет `-print`/`-print0`, результат
/// дополняется печатью: `find` без действий выводит всё, что прошло проверку.
final class _ExpressionParser {
  _ExpressionParser(this._tokens);

  final List<String> _tokens;
  int _pos = 0;
  bool _hasAction = false;

  /// Разбирает всё выражение. Бросает [_FindSyntax] при ошибке.
  _Node parse() {
    if (_tokens.isEmpty) return _withDefaultPrint(const _Always());
    final root = _or();
    if (_pos < _tokens.length) {
      throw _FindSyntax("unexpected argument '${_tokens[_pos]}'");
    }
    return _withDefaultPrint(root);
  }

  _Node _or() {
    var left = _and();
    while (_peek == '-o') {
      _pos++;
      left = _Or(left, _and());
    }
    return left;
  }

  _Node _and() {
    var left = _unary();
    while (_peek != null && _peek != '-o' && _peek != ')') {
      if (_peek == '-a') _pos++;
      left = _And(left, _unary());
    }
    return left;
  }

  _Node _unary() {
    final token = _peek;
    if (token == '!') {
      _pos++;
      return _Not(_unary());
    }
    if (token == '(') {
      _pos++;
      final inner = _or();
      if (_peek != ')') throw const _FindSyntax("expected ')'");
      _pos++;
      return inner;
    }
    return _primary();
  }

  _Node _primary() {
    final token = _peek;
    if (token == null) throw const _FindSyntax('expression expected');
    _pos++;
    switch (token) {
      case '-print':
        _hasAction = true;
        return const _Print(zero: false);
      case '-print0':
        _hasAction = true;
        return const _Print(zero: true);
      case '-empty':
        return _Predicate(_empty);
      case '-name' || '-iname' || '-path' || '-ipath':
        final pattern = _argument(token);
        final regex = globToRegExp(
          pattern,
          caseInsensitive: token.startsWith('-i'),
        );
        final onPath = token.endsWith('path');
        return _Predicate((c) => regex.hasMatch(onPath ? c.display : c.name));
      case '-type':
        final kind = switch (_argument(token)) {
          'f' => VfsNodeKind.file,
          'd' => VfsNodeKind.dir,
          'l' => VfsNodeKind.symlink,
          final other => throw _FindSyntax('unknown argument to -type: $other'),
        };
        return _Predicate((c) => c.node.kind == kind);
      default:
        throw _FindSyntax("unknown predicate '$token'");
    }
  }

  /// Значение предиката со значением. Отсутствие — ошибка, как у GNU find.
  String _argument(String predicate) {
    if (_pos >= _tokens.length) {
      throw _FindSyntax("missing argument to '$predicate'");
    }
    return _tokens[_pos++];
  }

  String? get _peek => _pos < _tokens.length ? _tokens[_pos] : null;

  _Node _withDefaultPrint(_Node node) =>
      _hasAction ? node : _And(node, const _Print(zero: false));

  static FutureOr<bool> _empty(_Candidate c) async {
    if (c.node.kind == VfsNodeKind.file) return c.node.size == 0;
    if (c.node.kind == VfsNodeKind.dir) {
      return (await c.fs.list(c.node.path)).isEmpty;
    }
    return false;
  }
}
