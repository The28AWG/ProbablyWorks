/// Объявление переменных: `declare`, `readonly` и печать `declare -p`.
///
/// Атрибуты пишутся в [ShellState]. `-i` включается до присваивания, чтобы `010` стало восьмеричным.
/// `-r` включается после записи: `declare -r x=1` и создаёт значение, и защищает его.
library;

import 'package:probably_works/host/virtual/shell/shell_builtins.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/shell/shell_print.dart';
import 'package:probably_works/host/virtual/shell/shell_state.dart';
import 'package:probably_works/host/virtual/shell/shell_text.dart';

abstract final class ShellVarBuiltins {
  const ShellVarBuiltins._();

  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static final _assignment = RegExp(r'^([^=]*)(?:=(.*))?$', dotAll: true);

  /// `declare` и `readonly`. [readonly] делает `-r` включённым по умолчанию.
  static int declare(
    List<String> args,
    ShellBuiltinCall call, {
    bool readonly = false,
  }) {
    final command = readonly ? 'readonly' : 'declare';
    var functions = false;
    var namesOnly = false;
    var print = false;
    var indexed = false;
    var associative = false;
    var integer = false;
    var export = false;
    var protect = readonly;
    final names = <String>[];
    for (final arg in args) {
      if (arg == '--') continue;
      if (arg == '-p') {
        print = true;
        continue;
      }
      if ((arg.startsWith('-') || arg.startsWith('+')) &&
          arg.length > 1 &&
          !arg.contains('=')) {
        final enable = arg.startsWith('-');
        final flags = ShellText.cut(arg, 1);
        for (final unit in flags.codeUnits) {
          final flag = String.fromCharCode(unit);
          if (!enable) {
            call.error('$command: +$flag: invalid option');
            return 2;
          }
          switch (flag) {
            case 'f':
              functions = true;
            case 'F':
              namesOnly = true;
            case 'a':
              indexed = true;
            case 'A':
              associative = true;
            case 'i':
              integer = true;
            case 'r':
              protect = true;
            case 'x':
              export = true;
            case 'p':
              print = true;
            default:
              call.error('$command: -$flag: invalid option');
              return 2;
          }
        }
        continue;
      }
      names.add(arg);
    }
    if (functions || namesOnly) {
      if (indexed || associative || integer || export || protect || print) {
        call.error('$command: cannot use function flags with variable flags');
        return 2;
      }
      return _functions(names, call, namesOnly: namesOnly);
    }
    if (print && names.isEmpty) {
      final variables = call.state.variables();
      final keys = variables.keys.toList()..sort();
      for (final name in keys) {
        if (readonly && !variables[name]!.has(VarAttr.readonly)) continue;
        call.stdout.writeText('${_line(name, variables[name]!)}\n');
      }
      return 0;
    }
    if (names.isEmpty && !indexed && !associative && !integer && !protect) {
      call.error(
        '$command: supported forms are -a -A -i -r -x -p -f -F and NAME=value',
      );
      return 2;
    }
    var status = 0;
    for (final arg in names) {
      if (print) {
        final variable = call.state.variables()[arg];
        if (variable == null) {
          call.error('$command: $arg: not found');
          status = 1;
          continue;
        }
        call.stdout.writeText('${_line(arg, variable)}\n');
        continue;
      }
      final assignment = _assignment.firstMatch(arg);
      final name = assignment?.group(1) ?? arg;
      if (!_identifier.hasMatch(name)) {
        call.error("$command: `$arg': not a valid identifier");
        status = 1;
        continue;
      }
      try {
        _apply(
          call.state,
          name,
          value: assignment?.group(2),
          indexed: indexed,
          associative: associative,
          integer: integer,
          export: export,
          protect: protect,
        );
      } on ShellRuntimeError catch (e) {
        call.error('$command: ${e.message}');
        status = 1;
      }
    }
    return status;
  }

  static void _apply(
    ShellState state,
    String name, {
    required String? value,
    required bool indexed,
    required bool associative,
    required bool integer,
    required bool export,
    required bool protect,
  }) {
    final attrs = {if (integer) VarAttr.integer, if (export) VarAttr.export};
    if (attrs.isNotEmpty) state.declare(name, attrs);
    if (indexed) state.declareIndexed(name);
    if (associative) state.declareAssociative(name);
    if (value != null) state.set(name, value);
    if (protect) state.declare(name, {VarAttr.readonly});
  }

  static int _functions(
    List<String> names,
    ShellBuiltinCall call, {
    required bool namesOnly,
  }) {
    final functions = call.state.functions();
    final selected = names.isEmpty ? functions.keys.toList() : names;
    var status = 0;
    for (final name in selected) {
      final function = functions[name];
      if (function == null) {
        if (names.isNotEmpty) {
          call.error('declare: $name: not found');
          status = 1;
        }
        continue;
      }
      call.stdout.writeText(
        namesOnly ? 'declare -f $name\n' : '${printFunction(function)}\n',
      );
    }
    return status;
  }

  /// Строка `declare -p`: флаги и значение в кавычках, как у bash.
  static String _line(String name, ShellVar variable) {
    final letters = StringBuffer();
    if (variable.assoc != null) {
      letters.write('A');
    } else if (variable.indexed != null) {
      letters.write('a');
    }
    if (variable.has(VarAttr.integer)) letters.write('i');
    if (variable.has(VarAttr.readonly)) letters.write('r');
    if (variable.has(VarAttr.export)) letters.write('x');
    if (variable.has(VarAttr.upper)) letters.write('u');
    if (variable.has(VarAttr.lower)) letters.write('l');
    final flag = letters.isEmpty ? '--' : '-$letters';
    return 'declare $flag $name${_value(variable)}';
  }

  static String _value(ShellVar variable) {
    final assoc = variable.assoc;
    if (assoc != null) {
      if (assoc.isEmpty) return '';
      final parts = [
        for (final entry in assoc.entries)
          '[${_key(entry.key)}]=${_quote(entry.value)}',
      ];
      return '=(${parts.join(' ')} )';
    }
    final indexed = variable.indexed;
    if (indexed != null) {
      if (indexed.isEmpty) return '';
      final parts = [
        for (final entry in indexed.entries)
          '[${entry.key}]=${_quote(entry.value)}',
      ];
      return '=(${parts.join(' ')})';
    }
    final value = variable.value;
    if (value == null) return '';
    return '=${_quote(value)}';
  }

  static String _key(String text) =>
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(text) ? text : _quote(text);

  static String _quote(String text) =>
      '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll(r'$', r'\$')}"';

  /// `set`: опции `-e -u -x -E -T -o` и позиционные параметры `set --`.
  static int set(List<String> args, ShellBuiltinCall call) {
    final state = call.state;
    var i = 0;
    while (i < args.length) {
      final arg = args[i];
      if (arg == '--') {
        state.positional = args.sublist(i + 1);
        return 0;
      }
      if (arg == '-') {
        state.options.remove('xtrace');
        i++;
        continue;
      }
      if (!arg.startsWith('-') && !arg.startsWith('+')) {
        state.positional = args.sublist(i);
        return 0;
      }
      final enable = arg.startsWith('-');
      final flags = ShellText.cut(arg, 1);
      if (flags.isEmpty) {
        call.error('set: -: invalid option');
        return 2;
      }
      for (var k = 0; k < flags.length; k++) {
        final flag = flags[k];
        if (flag == 'o') {
          if (k != flags.length - 1) {
            call.error('set: -o: option requires an argument');
            return 2;
          }
          i++;
          if (i >= args.length) {
            if (!enable) {
              call.error('set: +o: option requires an argument');
              return 2;
            }
            _printOptions(call);
            return 0;
          }
          final name = args[i];
          if (!shellOptionNames.contains(name)) {
            call.error('set: $name: invalid option name');
            return 1;
          }
          if (enable) {
            state.options.add(name);
          } else {
            state.options.remove(name);
          }
          break;
        }
        final name = shellOptionLetters[flag];
        if (name == null) {
          call.error('set: ${enable ? '-' : '+'}$flag: invalid option');
          return 2;
        }
        if (enable) {
          state.options.add(name);
        } else {
          state.options.remove(name);
        }
      }
      i++;
    }
    return 0;
  }

  static void _printOptions(ShellBuiltinCall call) {
    final names = shellOptionNames.toList()..sort();
    for (final name in names) {
      final mark = call.state.options.contains(name) ? 'on' : 'off';
      call.stdout.writeText('set -o $name\t$mark\n');
    }
  }

  static Future<int> export(List<String> args, ShellBuiltinCall call) async {
    final state = call.state;
    if (args.isEmpty || args.first == '-p') {
      final variables = state.variables();
      final names =
          variables.keys
              .where((n) => variables[n]!.has(VarAttr.export))
              .toList()
            ..sort();
      for (final name in names) {
        call.stdout.writeText(
          'declare -x $name="${variables[name]!.scalar ?? ''}"\n',
        );
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
      state.declare(name, {VarAttr.export});
    }
    return status;
  }

  static Future<int> unset(List<String> args, ShellBuiltinCall call) async {
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
        state.removeFunction(arg);
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
      state.unset(arg);
    }
    return status;
  }
}
