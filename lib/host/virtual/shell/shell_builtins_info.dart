/// Справка и запуск без подмены функцией: `command`, `type`, `let`, `hash`.
library;

import 'package:probably_works/host/virtual/shell/shell_arithmetic.dart';
import 'package:probably_works/host/virtual/shell/shell_builtins.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/shell/shell_print.dart';

abstract final class ShellInfoBuiltins {
  const ShellInfoBuiltins._();

  /// `let выражение...`: каждый аргумент — арифметическое выражение, записи идут в переменные оболочки.
  /// Код 1, если значение последнего выражения равно 0, иначе 0. Без аргументов — ошибка, код 1.
  ///
  /// Первая ошибка прекращает обработку, как в bash: остальные аргументы уже не вычисляются.
  static int let(List<String> args, ShellBuiltinCall call) {
    if (args.isEmpty) {
      call.error('let: expression expected');
      return 1;
    }
    final state = call.state;
    var last = 0;
    for (final arg in args) {
      try {
        last = ShellArithmetic.evaluate(
          arg,
          state.readForArithmetic,
          state.writeForArithmetic,
          context: 'let',
        );
      } on ShellRuntimeError catch (e) {
        call.error(e.message);
        return 1;
      }
    }
    return last == 0 ? 1 : 0;
  }

  /// `command [-v] имя`: выполняет команду, не вызывая функцию с тем же именем.
  /// `-v` печатает, как имя будет найдено: функция и встроенная команда — само имя, апплет — `/bin/имя`.
  static Future<int> command(List<String> args, ShellBuiltinCall call) async {
    var describe = false;
    var index = 0;
    if (args.isNotEmpty && args.first == '-v') {
      describe = true;
      index = 1;
    }
    final names = args.sublist(index);
    if (names.isEmpty) return 0;
    if (describe) {
      var status = 0;
      for (final name in names) {
        if (call.state.function(name) != null ||
            ShellBuiltins.isBuiltin(name)) {
          call.stdout.writeText('$name\n');
        } else if (call.applets?.lookup(name) != null) {
          call.stdout.writeText('/bin/$name\n');
        } else {
          status = 1;
        }
      }
      return status;
    }
    final exec = call.execArgv;
    if (exec == null) return 127;
    return exec(names, functions: false);
  }

  /// `hash` не ведёт таблицу команд: процессов нет. Пустой вызов сообщает, что таблица пуста.
  static int hash(List<String> args, ShellBuiltinCall call) {
    if (args.isEmpty) {
      call.stdout.writeText('hash: hash table empty\n');
      return 0;
    }
    if (args.first.startsWith('-') && args.first != '-r') {
      call.error('hash: ${args.first}: invalid option');
      return 2;
    }
    return 0;
  }

  /// `type`: функция, встроенная команда или апплет `/bin/имя`. Нет имени — код 1.
  static int type(List<String> args, ShellBuiltinCall call) {
    if (args.isEmpty) {
      call.error('type: usage: type name [name ...]');
      return 2;
    }
    var status = 0;
    for (final name in args) {
      final function = call.state.function(name);
      if (function != null) {
        call.stdout.writeText(
          '$name is a function\n${printFunction(function)}\n',
        );
        continue;
      }
      if (ShellBuiltins.isBuiltin(name)) {
        call.stdout.writeText('$name is a shell builtin\n');
        continue;
      }
      if (call.applets?.lookup(name) != null) {
        call.stdout.writeText('$name is /bin/$name\n');
        continue;
      }
      call.error('type: $name: not found');
      status = 1;
    }
    return status;
  }
}
