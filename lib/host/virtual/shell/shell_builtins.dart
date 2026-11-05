import 'package:probably_works/host/virtual/shell/applets/applet.dart';
import 'package:probably_works/host/virtual/shell/shell_builtins_flow.dart';
import 'package:probably_works/host/virtual/shell/shell_builtins_info.dart';
import 'package:probably_works/host/virtual/shell/shell_builtins_io.dart';
import 'package:probably_works/host/virtual/shell/shell_builtins_vars.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/shell/shell_state.dart';
import 'package:probably_works/host/virtual/shell/shell_text.dart';
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
    'let',
    '.',
    'command',
    'declare',
    'dirs',
    'eval',
    'getopts',
    'hash',
    'mapfile',
    'popd',
    'readarray',
    'printf',
    'pushd',
    'readonly',
    'set',
    'source',
    'trap',
    'type',
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
    'cd' => ShellFlowBuiltins.cd(args, call),
    'export' => ShellVarBuiltins.export(args, call),
    'unset' => ShellVarBuiltins.unset(args, call),
    'exit' => ShellFlowBuiltins.exit(args, call),
    'read' => ShellIoBuiltins.read(args, call),
    'local' => _local(args, call),
    'shift' => _shift(args, call),
    'return' => ShellFlowBuiltins.fromFunction(args, call),
    'break' => _loopControl(args, call, continues: false),
    'continue' => _loopControl(args, call, continues: true),
    'let' => Future.value(ShellInfoBuiltins.let(args, call)),
    '.' => ShellFlowBuiltins.source(args, call, '.'),
    'source' => ShellFlowBuiltins.source(args, call, 'source'),
    'command' => ShellInfoBuiltins.command(args, call),
    'declare' => Future.value(ShellVarBuiltins.declare(args, call)),
    'dirs' => ShellFlowBuiltins.dirs(args, call),
    'getopts' => Future.value(ShellIoBuiltins.getopts(args, call)),
    'hash' => Future.value(ShellInfoBuiltins.hash(args, call)),
    'mapfile' ||
    'readarray' => Future.value(ShellIoBuiltins.mapfile(args, call)),
    'popd' => ShellFlowBuiltins.popd(args, call),
    'printf' => Future.value(ShellIoBuiltins.printf(args, call)),
    'pushd' => ShellFlowBuiltins.pushd(args, call),
    'readonly' => Future.value(
      ShellVarBuiltins.declare(args, call, readonly: true),
    ),
    'eval' => ShellFlowBuiltins.eval(args, call),
    'set' => Future.value(ShellVarBuiltins.set(args, call)),
    'trap' => Future.value(ShellFlowBuiltins.trap(args, call)),
    'type' => Future.value(ShellInfoBuiltins.type(args, call)),
    _ => Future.value(0),
  };

  /// `local [NAME[=VALUE]...]`: только внутри функции.
  static Future<int> _local(List<String> args, ShellBuiltinCall call) async {
    final state = call.state;
    if (state.functionDepth == 0) {
      call.error('local: can only be used in a function');
      return 1;
    }
    var indexed = false;
    var associative = false;
    final attrs = <VarAttr>{};
    var index = 0;
    while (index < args.length &&
        args[index].startsWith('-') &&
        args[index].length > 1 &&
        !args[index].contains('=')) {
      final flags = ShellText.cut(args[index], 1);
      for (final unit in flags.codeUnits) {
        switch (String.fromCharCode(unit)) {
          case 'a':
            indexed = true;
          case 'A':
            associative = true;
          case 'i':
            attrs.add(VarAttr.integer);
          case 'r':
            attrs.add(VarAttr.readonly);
          case 'x':
            attrs.add(VarAttr.export);
          default:
            call.error('local: -${String.fromCharCode(unit)}: invalid option');
            return 2;
        }
      }
      index++;
    }
    var status = 0;
    for (final arg in args.sublist(index)) {
      final assignment = _assignment.firstMatch(arg)!;
      final name = assignment.group(1)!;
      if (!_identifier.hasMatch(name)) {
        call.error("local: `$arg': not a valid identifier");
        status = 1;
        continue;
      }
      try {
        state.declareLocal(name, attrs: attrs);
        if (indexed) state.declareIndexed(name);
        if (associative) state.declareAssociative(name);
        if (assignment.group(2) case final value?) state.set(name, value);
      } on ShellRuntimeError catch (e) {
        call.error('local: ${e.message}');
        status = 1;
      }
    }
    return status;
  }

  /// `shift [N]`: сдвигает позиционные параметры на N. Сдвиг за пределы — код 1 без сообщения:
  /// bash так делает, когда параметров меньше, чем просят. Нечисло — сообщение и код 2.
  static Future<int> _shift(List<String> args, ShellBuiltinCall call) async {
    final state = call.state;
    if (args.isNotEmpty && int.tryParse(args.first) == null) {
      call.error('shift: ${args.first}: numeric argument required');
      return 2;
    }
    final count = args.isEmpty ? 1 : int.parse(args.first);
    if (count < 0) {
      call.error('shift: ${args.first}: shift count out of range');
      return 1;
    }
    if (count > state.positional.length) return 1;
    state.positional = state.positional.sublist(count);
    return 0;
  }

  /// `break [N]` и `continue [N]`. Вне цикла любой аргумент — предупреждение и код 0: bash не разбирает
  /// число, пока цикла нет. Внутри цикла нечисло завершает неинтерактивную оболочку с кодом 2.
  /// Счётчик меньше 1 печатает ошибку и выходит из всех циклов с кодом 1, в том числе для `continue`.
  /// Счётчик больше глубины обрезается до неё: лишние уровни не ошибка.
  static Future<int> _loopControl(
    List<String> args,
    ShellBuiltinCall call, {
    required bool continues,
  }) async {
    final name = continues ? 'continue' : 'break';
    final depth = call.state.loopDepth;
    if (depth == 0) {
      call.error("$name: only meaningful in a `for', `while', or `until' loop");
      return 0;
    }
    if (args.isNotEmpty && int.tryParse(args.first) == null) {
      call.error('$name: ${args.first}: numeric argument required');
      throw const ShellExit(2);
    }
    final requested = args.isEmpty ? 1 : int.parse(args.first);
    if (requested < 1) {
      call.error('$name: ${args.first}: loop count out of range');
      throw ShellBreak(depth, status: 1);
    }
    final levels = requested > depth ? depth : requested;
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
    this.applets,
    this.inSource = false,
    this.runText,
    this.execArgv,
  });

  final ShellState state;

  /// Вход команды. `read` берёт из него строку и продвигает позицию для следующих команд цикла.
  final ShellInput stdin;
  final ShellSink stdout;
  final ShellSink stderr;
  final VirtualFs fs;

  /// Строка скрипта, на которой стоит команда. Нужна для префикса ошибки.
  final int line;

  /// Реестр апплетов для `type`. null — апплеты не видны.
  final AppletRegistry? applets;

  /// Сейчас выполняется `source` или `.`. `return` завершает файл, а не сообщает об ошибке.
  final bool inSource;

  /// Выполняет текст в текущей оболочке (`eval`, `source`). null — команды недоступны.
  final Future<int> Function(String text, {required bool sourced})? runText;

  /// Запускает argv как команду. [functions] = false — не подменять имя функцией (`command`).
  final Future<int> Function(List<String> argv, {required bool functions})?
  execArgv;

  /// Печатает ошибку в формате bash: `bash: line N: сообщение`.
  void error(String message) =>
      stderr.writeText('bash: line $line: $message\n');
}
