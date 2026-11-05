import 'package:probably_works/host/virtual/posix_regex.dart';
import 'package:probably_works/host/virtual/shell/shell_arithmetic.dart';
import 'package:probably_works/host/virtual/shell/shell_ast.dart';
import 'package:probably_works/host/virtual/shell/shell_expander.dart';
import 'package:probably_works/host/virtual/shell/shell_state.dart';
import 'package:probably_works/host/virtual/shell/shell_text.dart';
import 'package:probably_works/host/virtual/vfs_access.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';

/// Вычисление `[[ ... ]]`.
///
/// Слова раскрываются без разбиения по IFS и без глобов. `&&` и `||` не вычисляют правую часть, если
/// результат уже известен. `==` и `!=` сравнивают с образцом, как `case`. `=~` — POSIX ERE; кавычки
/// внутри образца делают кусок буквальным. Совпавшие группы пишутся в массив `BASH_REMATCH`.
///
/// Сравнение строк идёт по байтам UTF-8, как в `LC_ALL=C`. Числовые операторы считают арифметику bash,
/// поэтому `010` — восьмеричное, а `x++` меняет переменную.
abstract final class ShellCond {
  const ShellCond._();

  static final _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Истина ли [expr]. Ошибки арифметики и `readonly` пробрасываются вызывающему.
  static Future<bool> evaluate(
    CondNode expr, {
    required ShellExpander expander,
    required ShellState state,
    required VirtualFs fs,
  }) async {
    switch (expr) {
      case CondOr(:final left, :final right):
        if (await evaluate(left, expander: expander, state: state, fs: fs)) {
          return true;
        }
        return evaluate(right, expander: expander, state: state, fs: fs);
      case CondAnd(:final left, :final right):
        if (!await evaluate(left, expander: expander, state: state, fs: fs)) {
          return false;
        }
        return evaluate(right, expander: expander, state: state, fs: fs);
      case CondNot(:final inner):
        return !await evaluate(inner, expander: expander, state: state, fs: fs);
      case CondGroup(:final inner):
        return evaluate(inner, expander: expander, state: state, fs: fs);
      case CondPrimary(:final op, :final left, :final right):
        return _primary(
          op,
          left,
          right,
          expander: expander,
          state: state,
          fs: fs,
        );
    }
  }

  static Future<bool> _primary(
    String? op,
    ShellWord? left,
    ShellWord? right, {
    required ShellExpander expander,
    required ShellState state,
    required VirtualFs fs,
  }) async {
    if (op == null) {
      return (await expander.text(left!)).isNotEmpty;
    }
    if (left == null) {
      return _unary(op, await expander.text(right!), state: state, fs: fs);
    }
    final lhs = await expander.text(left);
    if (op == '==' || op == '=') {
      return expander.matchesPattern(right!, lhs);
    }
    if (op == '!=') {
      return !await expander.matchesPattern(right!, lhs);
    }
    if (op == '=~') return _regex(lhs, right!, expander, state);
    if (op == '<' || op == '>') {
      final rhs = await expander.text(right!);
      final order = ShellText.toByteChars(lhs)
          .compareTo(ShellText.toByteChars(rhs));
      return op == '<' ? order < 0 : order > 0;
    }
    if (op == '-nt' || op == '-ot' || op == '-ef') {
      return _files(
        op,
        lhs,
        await expander.text(right!),
        fs: fs,
        cwd: state.cwd,
      );
    }
    final rhs = await expander.text(right!);
    final a = _number(lhs, state);
    final b = _number(rhs, state);
    return switch (op) {
      '-eq' => a == b,
      '-ne' => a != b,
      '-lt' => a < b,
      '-le' => a <= b,
      '-gt' => a > b,
      _ => a >= b,
    };
  }

  /// Унарные проверки файла, строки, опции и переменной. Неизвестные типы файлов (`-b`, `-c`, `-p`,
  /// `-S`, `-t`) в виртуальной ФС всегда ложны: там нет устройств, каналов и терминала.
  static Future<bool> _unary(
    String op,
    String arg, {
    required ShellState state,
    required VirtualFs fs,
  }) async {
    switch (op) {
      case '-n':
        return arg.isNotEmpty;
      case '-z':
        return arg.isEmpty;
      case '-v':
        return _variableSet(state, arg);
      case '-o':
        return state.options.contains(arg);
      case '-t' || '-b' || '-c' || '-p' || '-S' || '-g' || '-u' || '-k':
        return false;
    }
    final follow = op != '-L' && op != '-h';
    final node = await fs.stat(arg, cwd: state.cwd, followLast: follow);
    if (node == null) return false;
    return switch (op) {
      '-a' || '-e' => true,
      '-f' => node.kind == VfsNodeKind.file,
      '-d' => node.kind == VfsNodeKind.dir,
      '-s' => node.kind != VfsNodeKind.dir && node.size > 0,
      '-L' || '-h' => node.kind == VfsNodeKind.symlink,
      '-r' => vfsAllows(node, VfsAccess.read),
      '-w' => vfsAllows(node, VfsAccess.write),
      '-x' => vfsAllows(node, VfsAccess.execute),
      '-O' => node.uid == vfsAgentUid,
      '-G' => node.gid == vfsAgentGid,
      '-N' => false,
      _ => false,
    };
  }

  /// `[[ -v имя ]]` и `[[ -v имя[индекс] ]]`. Объявленная без значения переменная считается заданной.
  static bool _variableSet(ShellState state, String spec) {
    final bracket = spec.indexOf('[');
    if (bracket < 0) {
      return _name.hasMatch(spec) && state.variable(spec) != null;
    }
    if (!spec.endsWith(']')) return false;
    final name = ShellText.cut(spec, 0, bracket);
    if (!_name.hasMatch(name)) return false;
    final variable = state.variable(name);
    if (variable == null) return false;
    final key = ShellText.cut(spec, bracket + 1, spec.length - 1);
    final indexed = variable.indexed;
    if (indexed != null) {
      final index = int.tryParse(key);
      return index != null && indexed.containsKey(index);
    }
    final assoc = variable.assoc;
    if (assoc != null) return assoc.containsKey(key);
    return key == '0' && variable.value != null;
  }

  static Future<bool> _files(
    String op,
    String left,
    String right, {
    required VirtualFs fs,
    required String cwd,
  }) async {
    final a = await fs.stat(left, cwd: cwd);
    final b = await fs.stat(right, cwd: cwd);
    if (a == null || b == null) return false;
    return switch (op) {
      '-ef' => a.path == b.path,
      '-nt' => a.mtime > b.mtime,
      _ => a.mtime < b.mtime,
    };
  }

  /// `=~`. Некорректное выражение даёт ложь и очищает `BASH_REMATCH`, как несовпадение: сообщение bash
  /// для части таких шаблонов — ошибка разбора, её ловит парсер, а не этот путь.
  static Future<bool> _regex(
    String value,
    ShellWord pattern,
    ShellExpander expander,
    ShellState state,
  ) async {
    // И образец, и строка считаются байтами: `.` в C-локали покрывает один байт, а не символ Dart.
    final source = ShellText.toByteChars(await expander.extendedRegex(pattern));
    final RegExp expression;
    try {
      expression = PosixRegex.fromEre(source);
    } on FormatException {
      state.unset('BASH_REMATCH');
      return false;
    }
    final match = expression.firstMatch(ShellText.toByteChars(value));
    if (match == null) {
      state.unset('BASH_REMATCH');
      return false;
    }
    final groups = <String>[];
    for (var i = 0; i <= match.groupCount; i++) {
      groups.add(ShellText.fromByteChars(match.group(i) ?? ''));
    }
    state.setArray('BASH_REMATCH', groups);
    return true;
  }

  /// Числовое сравнение `[[ ]]`: то же выражение, что в `$((...))`.
  static int _number(String text, ShellState state) => ShellArithmetic.evaluate(
    text,
    state.readForArithmetic,
    state.writeForArithmetic,
  );
}
