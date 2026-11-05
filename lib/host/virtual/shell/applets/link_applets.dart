import 'package:probably_works/host/virtual/shell/applets/applet.dart';
import 'package:probably_works/host/virtual/shell/applets/applet_args.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/vfs_path.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';

/// Ссылки и права: `ln -s`, `readlink`, `realpath`, `chmod`. Жёсткие ссылки не реализованы: `ln` без `-s`
/// возвращает ошибку, а не создаёт копию, которая вела бы себя иначе.
final List<Applet> linkApplets = [
  const _Ln(),
  const _Readlink(),
  const _Realpath(),
  const _Chmod(),
];

/// `ln -s [-f] TARGET LINK` или `ln -s [-f] TARGET... DIR`. Цель записывается как есть (не
/// разворачивается), как у GNU. `-f` заменяет существующую запись.
final class _Ln implements Applet {
  const _Ln();

  @override
  String get name => 'ln';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'sf');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (!parsed.has('s')) {
      io.stderr.writeText('ln: hard links are not supported: use -s\n');
      return 1;
    }
    final operands = parsed.operands;
    if (operands.length < 2) {
      return usageError(
        io,
        name,
        "missing file operand after '${operands.isEmpty ? name : operands.first}'",
      );
    }
    final targets = operands.sublist(0, operands.length - 1);
    final last = operands.last;
    final lastIsDir =
        (await io.fs.stat(last, cwd: io.cwd))?.kind == VfsNodeKind.dir;
    if (targets.length > 1 && !lastIsDir) {
      io.stderr.writeText("ln: target '$last' is not a directory\n");
      return 1;
    }

    var status = 0;
    for (final target in targets) {
      final link = lastIsDir
          ? VfsPath.join(VfsPath.normalize(last, cwd: io.cwd), baseOf(target))
          : last;
      try {
        if (parsed.has('f') &&
            await io.fs.stat(link, cwd: io.cwd, followLast: false) != null) {
          await io.fs.remove(link, cwd: io.cwd);
        }
        await io.fs.symlink(target, link, cwd: io.cwd);
      } on VfsException catch (error) {
        io.stderr.writeText(
          'ln: failed to create symbolic link $link: ${error.message}\n',
        );
        status = 1;
      }
    }
    return status;
  }
}

/// `readlink [-fn] PATH...`: цель симлинка. Не симлинк — код 1 без вывода, как у GNU. `-f` выдаёт
/// канонический путь (все каталоги существуют, последний компонент может отсутствовать), `-n` — без
/// перевода строки.
final class _Readlink implements Applet {
  const _Readlink();

  @override
  String get name => 'readlink';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'fn');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.isEmpty) return usageError(io, name, 'missing operand');
    final newline = parsed.has('n') ? '' : '\n';
    var status = 0;
    for (final operand in parsed.operands) {
      if (parsed.has('f')) {
        try {
          io.stdout.writeText(
            '${await io.fs.realpath(operand, cwd: io.cwd)}$newline',
          );
        } on VfsException catch (error) {
          io.stderr.writeText('readlink: $operand: ${error.message}\n');
          status = 1;
        }
        continue;
      }
      final node = await io.fs.stat(operand, cwd: io.cwd, followLast: false);
      if (node?.kind != VfsNodeKind.symlink) {
        status = 1;
        continue;
      }
      io.stdout.writeText('${node?.target ?? ''}$newline');
    }
    return status;
  }
}

/// `realpath PATH...`: канонический путь. Как и `readlink -f`, последний компонент может отсутствовать.
final class _Realpath implements Applet {
  const _Realpath();

  @override
  String get name => 'realpath';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args);
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.isEmpty) return usageError(io, name, 'missing operand');
    var status = 0;
    for (final operand in parsed.operands) {
      try {
        io.stdout.writeText('${await io.fs.realpath(operand, cwd: io.cwd)}\n');
      } on VfsException catch (error) {
        io.stderr.writeText('realpath: $operand: ${error.message}\n');
        status = 1;
      }
    }
    return status;
  }
}

/// `chmod [-R] MODE FILE...`. MODE — восьмеричный (`755`) или символьный (`u+x`, `go-w`, `a=r`, `+X`).
/// Права меняются через симлинк на его цель. Биты setuid/setgid/sticky в восьмеричной записи отбрасываются:
/// VFS хранит только права доступа. Маска umask не применяется: `+x` без класса затрагивает все три.
final class _Chmod implements Applet {
  const _Chmod();

  @override
  String get name => 'chmod';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'R');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    if (parsed.operands.length < 2) {
      return usageError(
        io,
        name,
        "missing operand after '${parsed.operands.isEmpty ? name : parsed.operands.first}'",
      );
    }
    final modeText = parsed.operands.first;
    final change = _parseMode(modeText);
    if (change == null) {
      io.stderr.writeText("chmod: invalid mode: '$modeText'\n");
      return 1;
    }
    var status = 0;
    for (final file in parsed.operands.skip(1)) {
      try {
        await _apply(io, file, change: change, recursive: parsed.has('R'));
      } on VfsException catch (error) {
        io.stderr.writeText("chmod: cannot access '$file': ${error.message}\n");
        status = 1;
      }
    }
    return status;
  }

  Future<void> _apply(
    AppletIo io,
    String path, {
    required _ModeChange change,
    required bool recursive,
  }) async {
    final node = await io.fs.stat(path, cwd: io.cwd);
    if (node == null) throw const VfsException('No such file or directory');
    final isDir = node.kind == VfsNodeKind.dir;
    await io.fs.chmod(node.path, change(node.mode, isDir));
    if (!recursive || !isDir) return;
    for (final child in await io.fs.list(node.path)) {
      await _apply(io, child.path, change: change, recursive: true);
    }
  }
}

/// Преобразование прав: по текущему режиму и признаку каталога возвращает новый режим.
typedef _ModeChange = int Function(int mode, bool isDir);

/// Разбор MODE: восьмеричный или символьный. Null — формат не распознан.
_ModeChange? _parseMode(String text) {
  if (RegExp(r'^[0-7]{1,4}$').hasMatch(text)) {
    final value = int.parse(text, radix: 8) & 0x1ff;
    return (mode, isDir) => value;
  }
  final clauses = <_Clause>[];
  for (final part in text.split(',')) {
    final match = RegExp(r'^([ugoa]*)((?:[-+=][rwxX]*)+)$').firstMatch(part);
    if (match == null) return null;
    final who = match.group(1) ?? '';
    final shifts = who.isEmpty || who.contains('a')
        ? const [6, 3, 0]
        : [
            if (who.contains('u')) 6,
            if (who.contains('g')) 3,
            if (who.contains('o')) 0,
          ];
    for (final op in RegExp(
      r'([-+=])([rwxX]*)',
    ).allMatches(match.group(2) ?? '')) {
      clauses.add(_Clause(op.group(1)!, shifts, op.group(2) ?? ''));
    }
  }
  return (mode, isDir) {
    var result = mode;
    for (final clause in clauses) {
      // `X` даёт право на выполнение только каталогу или файлу, который уже исполняем.
      final execAllowed = isDir || (result & 0x49) != 0;
      var value = 0;
      if (clause.perms.contains('r')) value |= 4;
      if (clause.perms.contains('w')) value |= 2;
      if (clause.perms.contains('x') ||
          (execAllowed && clause.perms.contains('X'))) {
        value |= 1;
      }
      var bits = 0;
      var classes = 0;
      for (final shift in clause.shifts) {
        bits |= value << shift;
        classes |= 7 << shift;
      }
      result = switch (clause.op) {
        '+' => result | bits,
        '-' => result & ~bits,
        _ => (result & ~classes) | bits,
      };
    }
    return result & 0x1ff;
  };
}

/// Одна операция символьного режима: оператор, классы (сдвиги: u — 6, g — 3, o — 0) и права.
final class _Clause {
  const _Clause(this.op, this.shifts, this.perms);

  final String op;
  final List<int> shifts;
  final String perms;
}
