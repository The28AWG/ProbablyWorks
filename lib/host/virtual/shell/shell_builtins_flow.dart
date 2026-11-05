/// Управление выполнением: ловушки, выход, `eval`/`source`, каталоги.
library;

import 'dart:convert';

import 'package:probably_works/host/virtual/shell/shell_builtins.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/shell/shell_state.dart';
import 'package:probably_works/host/virtual/vfs_path.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';

/// `trap`, `exit`, `return`, `eval`, `source`, `cd`, `pushd`, `popd`, `dirs`.
abstract final class ShellFlowBuiltins {
  const ShellFlowBuiltins._();

  static const _signals = {'EXIT', 'ERR', 'RETURN', 'INT', 'TERM'};

  /// `trap команда СИГНАЛ`. Поддержаны EXIT, ERR, RETURN, INT и TERM. `-` снимает ловушку.
  static int trap(List<String> args, ShellBuiltinCall call) {
    final state = call.state;
    if (args.isEmpty) {
      for (final MapEntry(:key, :value) in state.traps.entries) {
        call.stdout.writeText("trap -- '$value' $key\n");
      }
      return 0;
    }
    if (args.length == 1 && _signals.contains(args.first)) {
      final command = state.traps[args.first];
      if (command != null) {
        call.stdout.writeText("trap -- '$command' ${args.first}\n");
      }
      return 0;
    }
    if (args.first == '-') {
      for (final name in args.skip(1)) {
        if (!_signals.contains(name)) {
          call.error('trap: $name: invalid signal specification');
          return 1;
        }
        state.traps.remove(name);
      }
      return 0;
    }
    if (args.length < 2) {
      call.error('trap: usage: trap [-lp] [[arg] signal_spec ...]');
      return 2;
    }
    final command = args.first;
    var status = 0;
    for (final name in args.skip(1)) {
      if (!_signals.contains(name)) {
        call.error('trap: $name: invalid signal specification');
        status = 1;
        continue;
      }
      if (command.isEmpty) {
        state.traps.remove(name);
      } else {
        state.traps[name] = command;
      }
    }
    return status;
  }

  static Future<int> cd(List<String> args, ShellBuiltinCall call) async {
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

  static Future<int> exit(List<String> args, ShellBuiltinCall call) async {
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

  /// `return [N]`: только в функции. Без аргумента — код последней команды.
  static Future<int> fromFunction(
    List<String> args,
    ShellBuiltinCall call,
  ) async {
    if (call.state.functionDepth == 0 && !call.inSource) {
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

  /// `eval` склеивает аргументы пробелом и выполняет их в текущей оболочке.
  static Future<int> eval(List<String> args, ShellBuiltinCall call) {
    final run = call.runText;
    if (run == null || args.isEmpty) return Future.value(0);
    return run(args.join(' '), sourced: false);
  }

  /// `source` и `.`: читают файл из виртуальной ФС и выполняют его в текущей оболочке.
  /// Аргументы после имени становятся позиционными на время файла и затем возвращаются.
  static Future<int> source(
    List<String> args,
    ShellBuiltinCall call,
    String command,
  ) async {
    if (args.isEmpty) {
      call.error('$command: filename argument required');
      return 2;
    }
    final run = call.runText;
    if (run == null) return 1;
    final path = args.first;
    final String text;
    try {
      final bytes = await call.fs.readBytes(path, cwd: call.state.cwd);
      text = utf8.decode(bytes, allowMalformed: true);
    } on VfsException catch (e) {
      call.error('$command: $path: ${e.message}');
      return 1;
    }
    final saved = call.state.positional;
    if (args.length > 1) call.state.positional = args.sublist(1);
    try {
      return await run(text, sourced: true);
    } finally {
      call.state.positional = saved;
    }
  }

  /// Каталоги стека `pushd`: текущий каталог и то, что положили раньше. Ближний — сразу после текущего.
  static String _dirsLine(ShellState state) =>
      [state.cwd, ...state.dirStack].join(' ');

  static Future<int> dirs(List<String> args, ShellBuiltinCall call) async {
    if (args.isEmpty) {
      call.stdout.writeText('${_dirsLine(call.state)}\n');
      return 0;
    }
    if (args.first == '-c' && args.length == 1) {
      call.state.dirStack.clear();
      return 0;
    }
    call.error('dirs: ${args.first}: invalid option');
    return 2;
  }

  /// `pushd каталог` запоминает текущий каталог и переходит. Без аргумента меняет местами вершину стека.
  static Future<int> pushd(List<String> args, ShellBuiltinCall call) async {
    final state = call.state;
    if (args.isEmpty) {
      if (state.dirStack.isEmpty) {
        call.error('pushd: no other directory');
        return 1;
      }
      final top = state.dirStack.removeAt(0);
      final previous = state.cwd;
      final code = await _changeDir(top, call);
      if (code != 0) {
        state.dirStack.insert(0, top);
        return code;
      }
      state.dirStack.insert(0, previous);
      call.stdout.writeText('${_dirsLine(state)}\n');
      return 0;
    }
    if (args.length > 1) {
      call.error('pushd: too many arguments');
      return 1;
    }
    final previous = state.cwd;
    final code = await _changeDir(args.first, call);
    if (code != 0) return code;
    state.dirStack.insert(0, previous);
    call.stdout.writeText('${_dirsLine(state)}\n');
    return 0;
  }

  /// `popd` возвращает каталог с вершины стека.
  static Future<int> popd(List<String> args, ShellBuiltinCall call) async {
    if (args.isNotEmpty) {
      call.error('popd: too many arguments');
      return 1;
    }
    final state = call.state;
    if (state.dirStack.isEmpty) {
      call.error('popd: directory stack empty');
      return 1;
    }
    final top = state.dirStack.removeAt(0);
    final code = await _changeDir(top, call);
    if (code != 0) {
      state.dirStack.insert(0, top);
      return code;
    }
    call.stdout.writeText('${_dirsLine(state)}\n');
    return 0;
  }

  /// Переход в каталог без печати и без записи в стек. Ошибки — как у `cd`.
  static Future<int> _changeDir(String target, ShellBuiltinCall call) async {
    final state = call.state;
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
    return 0;
  }
}
