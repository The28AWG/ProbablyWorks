import 'dart:convert';
import 'dart:typed_data';

import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/virtual/shell/applets/applet.dart';
import 'package:probably_works/host/virtual/shell/shell_ast.dart';
import 'package:probably_works/host/virtual/shell/shell_builtins.dart';
import 'package:probably_works/host/virtual/shell/shell_errors.dart';
import 'package:probably_works/host/virtual/shell/shell_expander.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/shell/shell_parser.dart';
import 'package:probably_works/host/virtual/shell/shell_state.dart';
import 'package:probably_works/host/virtual/vfs_path.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';
import 'package:probably_works/host/virtual/virtual_limits.dart';
import 'package:probably_works/host/virtual/virtual_profile.dart';

/// Интерпретатор ограниченного bash-подмножества поверх виртуальной ФС одного Host.
///
/// Скрипт разбирается целиком до запуска: синтаксическая или неподдерживаемая конструкция не запускает
/// ни одной команды. Затем команды выполняются по порядку. Пайпы работают через буферы: стадия
/// завершается полностью, и её stdout передаётся следующей. Процессов нет: команда — это встроенная
/// команда, апплет из [applets] или функция, определённая в самом скрипте.
///
/// Сообщения об ошибках повторяют формат `bash -c` (`bash: line N: ...`), потому что модель обучена
/// на bash и узнаёт их без перевода.
final class ShellInterpreter {
  ShellInterpreter({
    required this.fs,
    required this.applets,
    required this.profile,
  });

  final VirtualFs fs;
  final AppletRegistry applets;
  final VirtualProfile profile;

  VirtualLimits get limits => fs.limits;

  /// Выполняет [command] в каталоге [cwd] (по умолчанию домашний каталог) и отдаёт события как
  /// [HostRuntime.run]: stdout и stderr по мере записи, в конце [ExecDone] с кодом выхода.
  /// Состояние оболочки (cd, переменные, функции) живёт только в этом запуске.
  Stream<ExecEvent> run(String command, {String? cwd, Uint8List? stdin}) =>
      Stream.fromFuture(
        _execute(command, cwd ?? profile.home, stdin ?? Uint8List(0)),
      ).expand((events) => events);

  Future<List<ExecEvent>> _execute(
    String command,
    String cwd,
    Uint8List stdin,
  ) async {
    final run = _Run(limits);
    final streams = _Io(
      ShellInput(stdin),
      EventSink(run.events, isStderr: false, budget: run.budget),
      EventSink(run.events, isStderr: true, budget: run.budget),
    );
    final code = await _program(command, cwd, streams, run);
    if (run.budget.truncated) {
      // Бюджет исчерпан, и обычный приёмник уже не пишет. Сообщение добавляется напрямую.
      final note = utf8.encode(
        'bash: output limit of ${limits.maxOutputBytes} bytes exceeded; '
        'the rest was dropped\n',
      );
      run.events.add(ExecStderr(Uint8List.fromList(note)));
    }
    run.events.add(ExecDone(exitCode: code));
    return run.events;
  }

  Future<int> _program(String command, String cwd, _Io io, _Run run) async {
    if (command.length > limits.maxCommandLength) {
      io.stderr.writeText(
        'bash: command is longer than ${limits.maxCommandLength} characters\n',
      );
      return 2;
    }
    try {
      final script = ShellParser.parse(command, limits: limits);
      final state = ShellState.initial(profile, cwd);
      return await _Evaluator(
        fs,
        applets,
        profile,
        run,
      ).script(script, state, io);
    } on ShellSyntaxException catch (e) {
      io.stderr.writeText('${e.text}\n');
      return 2;
    } on ShellExit catch (e) {
      return e.code;
    } on ShellLimitExceeded catch (e) {
      io.stderr.writeText('bash: ${e.message}\n');
      return e.exitCode;
    } on VfsException catch (e) {
      io.stderr.writeText('bash: ${e.message}\n');
      return 1;
    }
  }
}

/// Потоки команды: вход целиком в памяти, stdout и stderr — приёмники. Перенаправления заменяют их
/// на копии, поэтому изменения одной команды не видны соседям.
final class _Io {
  _Io(this.stdin, this.stdout, this.stderr);

  /// Вход разделяется командами одного места (цикла, функции), поэтому его позиция общая.
  ShellInput stdin;
  ShellSink stdout;
  ShellSink stderr;

  _Io copy() => _Io(stdin, stdout, stderr);
}

/// Учёт одного запуска: события, бюджет вывода, число команд и время.
final class _Run {
  _Run(this._limits) : budget = OutputBudget(_limits.maxOutputBytes);

  final VirtualLimits _limits;
  final OutputBudget budget;
  final List<ExecEvent> events = [];
  final Stopwatch _elapsed = Stopwatch()..start();
  int _commands = 0;

  /// Учитывает команду и проверяет время. Вызывается перед каждой командой, в том числе составной:
  /// так бесконечный цикл с пустым телом тоже останавливается лимитом.
  void countCommand() {
    _commands++;
    if (_commands > _limits.maxCommandsPerRun) {
      throw ShellLimitExceeded(
        'too many commands in one run (limit ${_limits.maxCommandsPerRun})',
      );
    }
    if (_elapsed.elapsed > _limits.runTimeout) {
      throw ShellLimitExceeded(
        'command timed out after ${_limits.runTimeout.inSeconds} seconds',
        exitCode: 124,
      );
    }
  }
}

/// Результат одной итерации цикла: код тела и признак, что цикл надо прервать (`break`).
typedef _Step = ({int status, bool stop});

/// Исполнитель одного запуска: рекурсивный обход дерева разбора.
final class _Evaluator {
  _Evaluator(this._fs, this._applets, this._profile, this._run);

  final VirtualFs _fs;
  final AppletRegistry _applets;
  final VirtualProfile _profile;
  final _Run _run;

  VirtualLimits get _limits => _fs.limits;

  /// Скрипт: цепочки выполняются по порядку. Возвращает код последней.
  Future<int> script(ScriptNode node, ShellState state, _Io io) async {
    var status = 0;
    for (final list in node.lists) {
      status = await _andOr(list, state, io);
    }
    return status;
  }

  /// `&&` и `||` идут слева направо с одинаковым приоритетом, как в bash. Пропущенный конвейер не
  /// меняет код выхода, поэтому `false && a || b` запускает `b`.
  Future<int> _andOr(AndOrList list, ShellState state, _Io io) async {
    var status = await _pipeline(list.pipelines.first, state, io);
    state.lastStatus = status;
    for (var i = 0; i < list.operators.length; i++) {
      final runNext = switch (list.operators[i]) {
        AndOrOperator.and => status == 0,
        AndOrOperator.or => status != 0,
      };
      if (!runNext) continue;
      status = await _pipeline(list.pipelines[i + 1], state, io);
      state.lastStatus = status;
    }
    return status;
  }

  Future<int> _pipeline(Pipeline pipeline, ShellState state, _Io io) async {
    final status = pipeline.commands.length == 1
        ? await _command(pipeline.commands.single, state, io)
        : await _stages(pipeline.commands, state, io);
    if (!pipeline.negated) return status;
    return status == 0 ? 1 : 0;
  }

  /// Конвейер. Каждая стадия работает в копии состояния (как подоболочка в bash), её stdout уходит в
  /// буфер, который становится stdin следующей стадии. Код — код последней стадии.
  Future<int> _stages(
    List<ShellCommand> commands,
    ShellState state,
    _Io io,
  ) async {
    var input = io.stdin;
    var status = 0;
    for (var i = 0; i < commands.length; i++) {
      final isLast = i == commands.length - 1;
      final buffer = isLast ? null : BufferSink(_limits.maxOutputBytes);
      final stage = _Io(input, buffer ?? io.stdout, io.stderr);
      final command = commands[i];
      status = await _isolated(() => _command(command, state.fork(), stage));
      if (buffer != null) {
        if (buffer.truncated) {
          io.stderr.writeText(
            'bash: pipe buffer of ${_limits.maxOutputBytes} bytes exceeded; '
            'the rest was dropped\n',
          );
        }
        input = ShellInput(buffer.bytes);
      }
    }
    return status;
  }

  /// Выполнение в подоболочке: `exit`, `return` и управление циклом внутри неё завершают только её.
  /// Так же ведёт себя bash: пайп, `( )` и `$(...)` не выходят наружу.
  Future<int> _isolated(Future<int> Function() run) async {
    try {
      return await run();
    } on ShellExit catch (e) {
      return e.code;
    } on ShellReturn catch (e) {
      return e.status;
    } on ShellBreak {
      return 0;
    } on ShellContinue {
      return 0;
    }
  }

  /// Одна команда. Счётчик лимитов учитывает и составные, и простые; ошибка выполнения (например, деление
  /// на ноль в `$((...))`) отменяет только эту команду.
  Future<int> _command(ShellCommand cmd, ShellState state, _Io io) async {
    _run.countCommand();
    try {
      return switch (cmd) {
        SimpleCommand() => await _simpleCommand(cmd, state, io),
        CompoundCommand() => await _compoundCommand(cmd, state, io),
        FunctionDefinition() => _define(cmd, state),
      };
    } on ShellRuntimeError catch (e) {
      io.stderr.writeText('bash: line ${cmd.line}: ${e.message}\n');
      return 1;
    }
  }

  Future<int> _simpleCommand(
    SimpleCommand cmd,
    ShellState state,
    _Io io,
  ) async {
    final expander = _expander(state, io);
    final opened = <FileSink>[];
    var status = 0;
    try {
      status = await _simple(cmd, state, io, expander, opened);
    } finally {
      // Закрытие выполняется даже при `exit`: файлы должны получить то, что команда успела записать.
      status = await _closeAll(opened, io, cmd.line, status);
    }
    return status;
  }

  Future<int> _simple(
    SimpleCommand cmd,
    ShellState state,
    _Io io,
    ShellExpander expander,
    List<FileSink> opened,
  ) async {
    final fields = <String>[];
    for (final word in cmd.words) {
      fields.addAll(await expander.fields(word));
    }
    final values = <String, String>{};
    for (final assignment in cmd.assignments) {
      values[assignment.name] = await expander.text(assignment.value);
    }
    final streams = io.copy();
    if (!await _redirect(
      cmd.redirects,
      expander,
      io,
      streams,
      opened,
      cmd.line,
    )) {
      return 1;
    }
    if (fields.isEmpty) {
      // Присваивание без команды меняет оболочку. Код — код последней подстановки или 0.
      for (final entry in values.entries) {
        state.set(entry.key, entry.value);
      }
      return expander.substitutionStatus ?? 0;
    }
    return _invoke(fields, values, state, streams, cmd.line);
  }

  /// Составная команда с её перенаправлениями: они применяются один раз ко всей конструкции.
  Future<int> _compoundCommand(
    CompoundCommand cmd,
    ShellState state,
    _Io io,
  ) async {
    final expander = _expander(state, io);
    final streams = io.copy();
    final opened = <FileSink>[];
    var status = 0;
    try {
      status =
          await _redirect(
            cmd.redirects,
            expander,
            io,
            streams,
            opened,
            cmd.line,
          )
          ? await _compound(cmd, state, streams)
          : 1;
    } finally {
      status = await _closeAll(opened, io, cmd.line, status);
    }
    return status;
  }

  Future<int> _compound(CompoundCommand cmd, ShellState state, _Io io) =>
      switch (cmd) {
        SubshellCommand() => _isolated(
          () => script(cmd.body, state.fork(), io),
        ),
        GroupCommand() => script(cmd.body, state, io),
        IfCommand() => _if(cmd, state, io),
        LoopCommand() => _loop(cmd, state, io),
        ForCommand() => _for(cmd, state, io),
        CaseCommand() => _case(cmd, state, io),
      };

  Future<int> _if(IfCommand cmd, ShellState state, _Io io) async {
    for (final branch in cmd.branches) {
      if (await script(branch.condition, state, io) == 0) {
        return script(branch.body, state, io);
      }
    }
    final elseBody = cmd.elseBody;
    return elseBody == null ? 0 : script(elseBody, state, io);
  }

  /// `while` и `until`. Код цикла — код последнего выполненного тела; если тело не выполнялось, 0.
  Future<int> _loop(LoopCommand cmd, ShellState state, _Io io) async {
    var status = 0;
    state.loopDepth++;
    try {
      while (true) {
        final condition = await script(cmd.condition, state, io);
        if (cmd.until ? condition == 0 : condition != 0) break;
        final step = await _iteration(cmd.body, state, io);
        status = step.status;
        if (step.stop) break;
      }
    } finally {
      state.loopDepth--;
    }
    return status;
  }

  Future<int> _for(ForCommand cmd, ShellState state, _Io io) async {
    final expander = _expander(state, io);
    final values = <String>[];
    final words = cmd.words;
    if (words == null) {
      values.addAll(state.positional);
    } else {
      for (final word in words) {
        values.addAll(await expander.fields(word));
      }
    }
    var status = 0;
    state.loopDepth++;
    try {
      for (final value in values) {
        state.set(cmd.variable, value);
        final step = await _iteration(cmd.body, state, io);
        status = step.status;
        if (step.stop) break;
      }
    } finally {
      state.loopDepth--;
    }
    return status;
  }

  /// Одна итерация цикла. `break N` прерывает цикл, `continue N` переходит к следующей итерации. Если N
  /// больше единицы, исключение поднимается к внешнему циклу с уменьшенным счётчиком.
  Future<_Step> _iteration(ScriptNode body, ShellState state, _Io io) async {
    try {
      return (status: await script(body, state, io), stop: false);
    } on ShellBreak catch (e, stack) {
      if (e.levels > 1) {
        Error.throwWithStackTrace(ShellBreak(e.levels - 1), stack);
      }
      return (status: 0, stop: true);
    } on ShellContinue catch (e, stack) {
      if (e.levels > 1) {
        Error.throwWithStackTrace(ShellContinue(e.levels - 1), stack);
      }
      return (status: 0, stop: false);
    }
  }

  /// `case`. Первая ветка с подходящим образцом выполняется. `;&` запускает следующую ветку без проверки,
  /// `;;&` продолжает проверку образцов.
  Future<int> _case(CaseCommand cmd, ShellState state, _Io io) async {
    final expander = _expander(state, io);
    final subject = await expander.text(cmd.subject);
    var status = 0;
    var forced = false;
    for (final clause in cmd.clauses) {
      var selected = forced;
      if (!selected) {
        for (final pattern in clause.patterns) {
          if (await expander.matchesPattern(pattern, subject)) {
            selected = true;
            break;
          }
        }
      }
      if (!selected) continue;
      status = await script(clause.body, state, io);
      switch (clause.terminator) {
        case CaseTerminator.stop:
          return status;
        case CaseTerminator.fallthrough:
          forced = true;
        case CaseTerminator.testNext:
          forced = false;
      }
    }
    return status;
  }

  /// Определение функции: запись в состояние. Тело не выполняется.
  int _define(FunctionDefinition cmd, ShellState state) {
    state.functions[cmd.name] = cmd;
    return 0;
  }

  /// Применяет перенаправления слева направо. Возвращает false, если цель недоступна: тогда команда
  /// не запускается, а сообщение печатается в исходный stderr.
  Future<bool> _redirect(
    List<Redirect> redirects,
    ShellExpander expander,
    _Io io,
    _Io streams,
    List<FileSink> opened,
    int line,
  ) async {
    for (final redirect in redirects) {
      switch (redirect) {
        case HeredocRedirect(
          :final body,
          :final terminated,
          :final delimiter,
          :final line,
          :final eofLine,
        ):
          if (!terminated) {
            io.stderr.writeText(
              'bash: line $eofLine: warning: here-document at line $line '
              "delimited by end-of-file (wanted `$delimiter')\n",
            );
          }
          final text = await expander.text(body);
          streams.stdin = ShellInput(Uint8List.fromList(utf8.encode(text)));
        case FileRedirect():
          if (!await _fileRedirect(
            redirect,
            expander,
            io,
            streams,
            opened,
            line,
          )) {
            return false;
          }
      }
    }
    return true;
  }

  Future<bool> _fileRedirect(
    FileRedirect redirect,
    ShellExpander expander,
    _Io io,
    _Io streams,
    List<FileSink> opened,
    int line,
  ) async {
    final cwd = expander.state.cwd;
    if (redirect.kind == RedirectKind.hereString) {
      final text = await expander.text(redirect.target);
      streams.stdin = ShellInput(Uint8List.fromList(utf8.encode('$text\n')));
      return true;
    }
    if (redirect.kind == RedirectKind.dupOutput) {
      // Парсер пропускает только цели 1 и 2. Источник берётся из текущих потоков, как при `2>&1`.
      final source = await expander.text(redirect.target);
      final sink = source == '1' ? streams.stdout : streams.stderr;
      if (redirect.fd == 1) {
        streams.stdout = sink;
      } else {
        streams.stderr = sink;
      }
      return true;
    }
    final (fields, text) = await expander.fieldsAndText(redirect.target);
    if (fields.length != 1) {
      io.stderr.writeText('bash: line $line: $text: ambiguous redirect\n');
      return false;
    }
    final path = fields.single;
    final devNull = isDevNull(path, cwd);
    if (redirect.kind == RedirectKind.input) {
      if (devNull) {
        streams.stdin = ShellInput(Uint8List(0));
        return true;
      }
      try {
        streams.stdin = ShellInput(await _fs.readBytes(path, cwd: cwd));
      } on VfsException catch (e) {
        io.stderr.writeText('bash: line $line: $path: ${e.message}\n');
        return false;
      }
      return true;
    }
    final append = redirect.kind == RedirectKind.append;
    final ShellSink sink;
    if (devNull) {
      sink = NullSink();
    } else {
      try {
        final file = await FileSink.open(_fs, path, cwd: cwd, append: append);
        opened.add(file);
        sink = file;
      } on VfsException catch (e) {
        io.stderr.writeText('bash: line $line: $path: ${e.message}\n');
        return false;
      }
    }
    if (redirect.fd == 1) {
      streams.stdout = sink;
    } else {
      streams.stderr = sink;
    }
    return true;
  }

  Future<int> _closeAll(
    List<FileSink> files,
    _Io io,
    int line,
    int status,
  ) async {
    var result = status;
    for (final file in files) {
      try {
        await file.close();
      } on VfsException catch (e) {
        io.stderr.writeText('bash: line $line: ${file.path}: ${e.message}\n');
        result = 1;
      }
    }
    return result;
  }

  Future<int> _invoke(
    List<String> fields,
    Map<String, String> values,
    ShellState state,
    _Io streams,
    int line,
  ) async {
    final name = fields.first;
    final args = fields.sublist(1);
    // Функция, определённая в скрипте, перекрывает встроенные команды и апплеты, как в bash.
    final function = state.functions[name];
    if (function != null) {
      return _callFunction(function, args, values, state, streams);
    }
    if (ShellBuiltins.isBuiltin(name)) {
      return ShellBuiltins.run(
        name,
        args,
        ShellBuiltinCall(
          state: state,
          stdin: streams.stdin,
          stdout: streams.stdout,
          stderr: streams.stderr,
          fs: _fs,
          line: line,
        ),
      );
    }
    final isPath = name.contains('/');
    final applet = isPath
        ? _pathApplet(name, state.cwd)
        : _applets.lookup(name);
    if (applet == null) {
      if (isPath) {
        return _pathNotRunnable(name, state.cwd, streams, line);
      }
      streams.stderr.writeText('bash: line $line: $name: command not found\n');
      return 127;
    }
    final input = streams.stdin;
    final io = AppletIo(
      readStdin: input.takeRest,
      stdout: streams.stdout,
      stderr: streams.stderr,
      cwd: state.cwd,
      env: {...state.environment(), ...values},
      fs: _fs,
      profile: _profile,
      applets: _applets,
      exec: _execArgv,
    );
    try {
      return await applet.run(io, args);
    } on VfsException catch (e) {
      streams.stderr.writeText('${applet.name}: ${e.message}\n');
      return 1;
    }
  }

  /// Вызов функции: позиционные параметры — её аргументы, `local` откатывается при выходе, `return`
  /// даёт код. Перенаправления тела функции применяются при вызове, как у составной команды.
  /// Присваивания перед вызовом (`X=1 f`) действуют на время вызова: их откат устроен как у `local`,
  /// поэтому после выхода прежнее значение возвращается.
  Future<int> _callFunction(
    FunctionDefinition function,
    List<String> args,
    Map<String, String> values,
    ShellState state,
    _Io io,
  ) async {
    final saved = state.enterFunction(args);
    // Внутри функции цикл вызывающего кода не виден: `break` в ней — предупреждение, как в bash.
    final callerLoops = state.loopDepth;
    state.loopDepth = 0;
    var status = 0;
    try {
      for (final entry in values.entries) {
        state.declareLocal(entry.key, entry.value);
      }
      status = await _command(function.body, state, io);
    } on ShellReturn catch (e) {
      status = e.status;
    } finally {
      state
        ..loopDepth = callerLoops
        ..leaveFunction(saved);
    }
    return status;
  }

  /// Вызов команды по argv без разбора строки (для `xargs` и подобных). Команды сверх реестра нет.
  Future<int> _execArgv(List<String> argv, AppletIo io) async {
    if (argv.isEmpty) return 0;
    final applet = _applets.lookup(argv.first);
    if (applet == null) {
      io.stderr.writeText('${argv.first}: command not found\n');
      return 127;
    }
    try {
      return await applet.run(io, argv.sublist(1));
    } on VfsException catch (e) {
      io.stderr.writeText('${applet.name}: ${e.message}\n');
      return 1;
    }
  }

  /// Путь вида `/bin/ls` или `/usr/bin/ls` запускает апплет. Другие пути — файлы, которые не исполняются.
  Applet? _pathApplet(String name, String cwd) {
    final canonical = VfsPath.normalize(name, cwd: cwd);
    final dir = VfsPath.parent(canonical);
    if (dir != '/bin' && dir != '/usr/bin') return null;
    return _applets.lookup(VfsPath.name(canonical));
  }

  /// Путь к несуществующему или обычному файлу. Скрипты на виртуальном Host не исполняются.
  Future<int> _pathNotRunnable(
    String name,
    String cwd,
    _Io streams,
    int line,
  ) async {
    final node = await _fs.stat(name, cwd: cwd);
    if (node == null) {
      streams.stderr.writeText(
        'bash: line $line: $name: No such file or directory\n',
      );
      return 127;
    }
    if (node.kind == VfsNodeKind.dir) {
      streams.stderr.writeText('bash: line $line: $name: Is a directory\n');
      return 126;
    }
    streams.stderr.writeText(
      'bash: line $line: $name: scripts are not supported on the virtual host\n',
    );
    return 126;
  }

  /// Расширитель для команды. Подстановка `$(...)` выполняется в копии состояния, её stdin и stderr
  /// совпадают с потоками команды, а stdout собирается буфером.
  ShellExpander _expander(ShellState state, _Io io) => ShellExpander(
    state: state,
    fs: _fs,
    home: _profile.home,
    substitute: (script) async {
      final buffer = BufferSink(_limits.maxOutputBytes);
      final inner = _Io(io.stdin, buffer, io.stderr);
      final status = await _isolated(
        () => this.script(script, state.fork(), inner),
      );
      if (buffer.truncated) {
        io.stderr.writeText(
          'bash: command substitution output exceeded '
          '${_limits.maxOutputBytes} bytes; the rest was dropped\n',
        );
      }
      return (buffer.bytes, status);
    },
  );
}
