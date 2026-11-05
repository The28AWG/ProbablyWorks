import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/shell/shell_state.dart';
import 'package:probably_works/host/virtual/vfs_path.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';

/// Встроенные команды: те, что меняют состояние самой оболочки (каталог, переменные, выход, цикл, функцию,
/// ввод). Остальные команды — апплеты. Список намеренно короткий: всё, что bash делает встроенным ради
/// скорости, здесь либо апплет, либо отсутствует.
abstract final class ShellBuiltins {
  const ShellBuiltins._();

  static const names = {
    'cd',
    'export',
    'unset',
    'exit',
    ':',
    'read',
    'local',
    'shift',
    'return',
    'break',
    'continue',
  };

  static bool isBuiltin(String name) => names.contains(name);

  /// Запускает встроенную команду [name] с аргументами [args]. Возвращает код выхода.
  /// Ошибки печатаются в [ShellBuiltinCall.stderr] с префиксом `bash: line N:`, как у bash.
  /// `exit`, `break`, `continue` и `return` бросают исключения: их ловят цикл, функция или запуск.
  static Future<int> run(
    String name,
    List<String> args,
    ShellBuiltinCall call,
  ) => switch (name) {
    'cd' => _cd(args, call),
    'export' => _export(args, call),
    'unset' => _unset(args, call),
    'exit' => _exit(args, call),
    'read' => _read(args, call),
    'local' => _local(args, call),
    'shift' => _shift(args, call),
    'return' => _return(args, call),
    'break' => _loopControl(args, call, continues: false),
    'continue' => _loopControl(args, call, continues: true),
    _ => Future.value(0),
  };

  static Future<int> _cd(List<String> args, ShellBuiltinCall call) async {
    if (args.length > 1) {
      call.error('cd: too many arguments');
      return 1;
    }
    final state = call.state;
    final printsTarget = args.isNotEmpty && args.first == '-';
    final target = switch (args) {
      [] => state.get('HOME'),
      ['-'] => state.get('OLDPWD'),
      [final dir] => dir,
      _ => null,
    };
    if (target == null) {
      call.error(args.isEmpty ? 'cd: HOME not set' : 'cd: OLDPWD not set');
      return 1;
    }
    final node = await call.fs.stat(target, cwd: state.cwd);
    if (node == null) {
      call.error('cd: $target: No such file or directory');
      return 1;
    }
    if (node.kind != VfsNodeKind.dir) {
      call.error('cd: $target: Not a directory');
      return 1;
    }
    final previous = state.cwd;
    final next = VfsPath.normalize(target, cwd: previous);
    state
      ..cwd = next
      ..set('OLDPWD', previous)
      ..set('PWD', next);
    if (printsTarget) call.stdout.writeText('$next\n');
    return 0;
  }

  static Future<int> _export(List<String> args, ShellBuiltinCall call) async {
    final state = call.state;
    if (args.isEmpty || args.first == '-p') {
      final names = state.exported.where(state.vars.containsKey).toList()
        ..sort();
      for (final name in names) {
        call.stdout.writeText('declare -x $name="${state.vars[name]}"\n');
      }
      return 0;
    }
    var status = 0;
    for (final arg in args) {
      if (arg.startsWith('-')) {
        call.error('export: $arg: invalid option');
        return 2;
      }
      final assignment = _assignment.firstMatch(arg);
      final name = assignment?.group(1) ?? arg;
      if (!_identifier.hasMatch(name)) {
        call.error("export: `$arg': not a valid identifier");
        status = 1;
        continue;
      }
      if (assignment?.group(2) case final value?) state.set(name, value);
      state.exported.add(name);
    }
    return status;
  }

  static Future<int> _unset(List<String> args, ShellBuiltinCall call) async {
    final state = call.state;
    var status = 0;
    // `-f` переключает имена на функции, `-v` возвращает к переменным (по умолчанию).
    var functionsMode = false;
    for (final arg in args) {
      if (arg == '-v' || arg == '-f') {
        functionsMode = arg == '-f';
        continue;
      }
      if (functionsMode) {
        state.functions.remove(arg);
        continue;
      }
      if (arg.startsWith('-')) {
        call.error('unset: $arg: invalid option');
        return 2;
      }
      if (!_identifier.hasMatch(arg)) {
        call.error("unset: `$arg': not a valid identifier");
        status = 1;
        continue;
      }
      state
        ..vars.remove(arg)
        ..exported.remove(arg);
    }
    return status;
  }

  static Future<int> _exit(List<String> args, ShellBuiltinCall call) async {
    if (args.length > 1) {
      call.error('exit: too many arguments');
      return 1;
    }
    if (args.isEmpty) throw ShellExit(call.state.lastStatus);
    final code = int.tryParse(args.first);
    if (code == null) {
      call.error('exit: ${args.first}: numeric argument required');
      throw const ShellExit(2);
    }
    // Как у bash: код по модулю 256, отрицательные — из дополнительного кода.
    throw ShellExit(code & 0xFF);
  }

  /// `read [-r] [NAME...]`: читает строку из [ShellBuiltinCall.stdin] и делит её по IFS между именами.
  /// Последнее имя получает остаток строки. Без имён — `REPLY`. Код 1, если вход кончился до перевода
  /// строки (или был пуст): значения всё равно присваиваются, как в bash.
  static Future<int> _read(List<String> args, ShellBuiltinCall call) async {
    var raw = false;
    var index = 0;
    while (index < args.length &&
        args[index].startsWith('-') &&
        args[index].length > 1) {
      final option = args[index];
      index++;
      if (option == '--') break;
      if (option != '-r') {
        call.error('read: $option: invalid option');
        return 2;
      }
      raw = true;
    }
    final names = args.sublist(index);
    for (final name in names) {
      if (!_identifier.hasMatch(name)) {
        call.error("read: `$name': not a valid identifier");
        return 1;
      }
    }
    final state = call.state;
    final ifs = state.get('IFS') ?? ' \t\n';
    final record = _readRecord(call.stdin, raw: raw);
    final chars = record?.chars ?? const <(String, bool)>[];
    _assign(state, names.isEmpty ? const ['REPLY'] : names, chars, ifs);
    return (record?.complete ?? false) ? 0 : 1;
  }

  /// Одна логическая строка для `read`: без `-r` строка, оканчивающаяся на нечётное число `\`, продолжается
  /// на следующей строке. Символы помечены, экранирован ли он: экранированный разделитель не делит поле.
  static ({List<(String, bool)> chars, bool complete})? _readRecord(
    ShellInput input, {
    required bool raw,
  }) {
    final first = input.readLine();
    if (first == null) return null;
    var text = first.text;
    var complete = first.terminated;
    if (!raw) {
      while (complete && _oddTrailingBackslash(text)) {
        // Последний символ — обратный слеш (ASCII), поэтому срез по единицам UTF-16 безопасен.
        text = String.fromCharCodes(text.codeUnits, 0, text.length - 1);
        final next = input.readLine();
        if (next == null) {
          complete = false;
          break;
        }
        text += next.text;
        complete = next.terminated;
      }
    }
    final units = [for (final rune in text.runes) String.fromCharCode(rune)];
    final chars = <(String, bool)>[];
    var i = 0;
    while (i < units.length) {
      if (!raw && units[i] == r'\' && i + 1 < units.length) {
        chars.add((units[i + 1], true));
        i += 2;
      } else if (!raw && units[i] == r'\') {
        i++;
      } else {
        chars.add((units[i], false));
        i++;
      }
    }
    return (chars: chars, complete: complete);
  }

  static bool _oddTrailingBackslash(String text) {
    var count = 0;
    for (var i = text.length - 1; i >= 0 && text[i] == r'\'; i--) {
      count++;
    }
    return count.isOdd;
  }

  /// Делит символы по IFS и присваивает имена. Пробельные разделители схлопываются, непробельный ставит
  /// границу; последнее имя получает остаток с обрезанными пробелами в конце.
  static void _assign(
    ShellState state,
    List<String> names,
    List<(String, bool)> chars,
    String ifs,
  ) {
    bool isIfs((String, bool) unit) => !unit.$2 && ifs.contains(unit.$1);
    bool isSpace((String, bool) unit) =>
        !unit.$2 && ' \t\n'.contains(unit.$1) && ifs.contains(unit.$1);
    var i = 0;
    for (var k = 0; k < names.length; k++) {
      final isLast = k == names.length - 1;
      while (i < chars.length && isSpace(chars[i])) {
        i++;
      }
      if (isLast) {
        var end = chars.length;
        while (end > i && isSpace(chars[end - 1])) {
          end--;
        }
        state.set(names[k], _text(chars.sublist(i, end)));
        break;
      }
      final start = i;
      while (i < chars.length && !isIfs(chars[i])) {
        i++;
      }
      state.set(names[k], _text(chars.sublist(start, i)));
      if (i < chars.length) i++;
    }
  }

  static String _text(List<(String, bool)> chars) =>
      chars.map((c) => c.$1).join();

  /// `local [NAME[=VALUE]...]`: только внутри функции.
  static Future<int> _local(List<String> args, ShellBuiltinCall call) async {
    final state = call.state;
    if (state.functionDepth == 0) {
      call.error('local: can only be used in a function');
      return 1;
    }
    var status = 0;
    for (final arg in args) {
      final assignment = _assignment.firstMatch(arg)!;
      final name = assignment.group(1)!;
      if (!_identifier.hasMatch(name)) {
        call.error("local: `$arg': not a valid identifier");
        status = 1;
        continue;
      }
      state.declareLocal(name, assignment.group(2));
    }
    return status;
  }

  /// `shift [N]`: сдвигает позиционные параметры на N. Сдвиг за пределы — ошибка, параметры не меняются.
  static Future<int> _shift(List<String> args, ShellBuiltinCall call) async {
    final state = call.state;
    final count = args.isEmpty ? 1 : int.tryParse(args.first);
    if (count == null || count < 0 || count > state.positional.length) {
      final shown = args.isEmpty ? '' : '${args.first}: ';
      call.error('shift: ${shown}shift count out of range');
      return 1;
    }
    state.positional = state.positional.sublist(count);
    return 0;
  }

  /// `return [N]`: только в функции. Без аргумента — код последней команды.
  static Future<int> _return(List<String> args, ShellBuiltinCall call) async {
    if (call.state.functionDepth == 0) {
      call.error("return: can only `return' from a function or sourced script");
      return 1;
    }
    if (args.isEmpty) throw ShellReturn(call.state.lastStatus);
    final code = int.tryParse(args.first);
    if (code == null) {
      call.error('return: ${args.first}: numeric argument required');
      throw const ShellReturn(2);
    }
    throw ShellReturn(code & 0xFF);
  }

  /// `break [N]` и `continue [N]`. Вне цикла bash печатает предупреждение и возвращает 0, так же и здесь.
  static Future<int> _loopControl(
    List<String> args,
    ShellBuiltinCall call, {
    required bool continues,
  }) async {
    final name = continues ? 'continue' : 'break';
    final levels = args.isEmpty ? 1 : int.tryParse(args.first);
    if (levels == null || levels < 1) {
      call.error('$name: ${args.first}: loop count out of range');
      return 1;
    }
    if (call.state.loopDepth == 0) {
      call.error("$name: only meaningful in a `for', `while', or `until' loop");
      return 0;
    }
    if (continues) throw ShellContinue(levels);
    throw ShellBreak(levels);
  }

  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// `NAME=value` или просто `NAME`. Значение может содержать `=` и переводы строк.
  static final _assignment = RegExp(r'^([^=]*)(?:=(.*))?$', dotAll: true);
}

/// Контекст вызова встроенной команды: состояние оболочки, приёмники, вход и файловая система.
final class ShellBuiltinCall {
  const ShellBuiltinCall({
    required this.state,
    required this.stdin,
    required this.stdout,
    required this.stderr,
    required this.fs,
    required this.line,
  });

  final ShellState state;

  /// Вход команды. `read` берёт из него строку и продвигает позицию для следующих команд цикла.
  final ShellInput stdin;
  final ShellSink stdout;
  final ShellSink stderr;
  final VirtualFs fs;

  /// Строка скрипта, на которой стоит команда. Нужна для префикса ошибки.
  final int line;

  /// Печатает ошибку в формате bash: `bash: line N: сообщение`.
  void error(String message) =>
      stderr.writeText('bash: line $line: $message\n');
}
