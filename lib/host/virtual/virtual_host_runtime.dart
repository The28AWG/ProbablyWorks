import 'dart:typed_data';

import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/host/virtual/shell/applets/applet.dart';
import 'package:probably_works/host/virtual/shell/shell_interpreter.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';
import 'package:probably_works/host/virtual/virtual_op_executor.dart';
import 'package:probably_works/host/virtual/virtual_profile.dart';

/// Рантайм виртуального Host: и операции, и команды выполняются над [VirtualFs] внутри процесса приложения.
///
/// Реальных процессов нет, поэтому событий [ExecStarted] не бывает: pid не выдаётся, фоновый запуск
/// и kill недоступны (их отсекает инструмент), а терминала нет ([hasTerminal] = false). Вызывающий код
/// выбирает путь по этим свойствам, а не по типу хоста, поэтому здесь нет проверок `kind`.
final class VirtualHostRuntime implements HostRuntime {
  VirtualHostRuntime({
    required VirtualFs fs,
    required VirtualProfile profile,
    required AppletRegistry applets,
  }) : _profile = profile,
       _operations = VirtualOpExecutor(
         fs,
         profile,
         commands: applets.names.toSet(),
       ),
       _shell = ShellInterpreter(fs: fs, applets: applets, profile: profile);

  final VirtualProfile _profile;
  final VirtualOpExecutor _operations;
  final ShellInterpreter _shell;

  /// Виртуальная система — POSIX-подобная: её команды и пути совпадают с Linux.
  @override
  HostOs get os => HostOs.posix;

  @override
  bool get hasTerminal => false;

  /// Выполняет операцию над VFS и отдаёт вывод событиями. Ошибки ФС уже превращены в код выхода и stderr,
  /// поэтому исключение сюда не доходит. Пустые stdout и stderr не отдаём, чтобы не плодить пустых событий.
  @override
  Stream<ExecEvent> perform(HostOp op, {String? cwd, Uint8List? stdin}) async* {
    final result = await _operations.execute(op, cwd: _cwd(cwd), stdin: stdin);
    if (result.stdout.isNotEmpty) yield ExecStdout(result.stdout);
    if (result.stderr.isNotEmpty) yield ExecStderr(result.stderr);
    yield ExecDone(exitCode: result.exitCode);
  }

  /// Выполняет строку команды интерпретатором оболочки; он сам отдаёт [ExecDone] с кодом выхода.
  /// Поток — тот же, что у интерпретатора: отписка отменяет запуск (ловушка INT, код 130).
  @override
  Stream<ExecEvent> run(String command, {String? cwd, Uint8List? stdin}) =>
      _shell.run(command, cwd: _cwd(cwd), stdin: stdin);

  /// Терминала у виртуального Host нет. Ошибка понятна модели: она должна запустить команду без фона.
  @override
  Future<HostTerminal> openTerminal(
    String command, {
    String? cwd,
    int columns = defaultTerminalColumns,
    int rows = defaultTerminalRows,
  }) => Future.error(
    const HostFailure(
      'virtual host has no terminal: run the command in the foreground',
    ),
  );

  /// Раскрывает `~` и `~/...` в домашний каталог профиля. Остальные пути (включая `~user`) не трогаем.
  /// Ошибка `~user` не маскируется: такой путь не существует и даст обычную ошибку ФС.
  String? _cwd(String? cwd) {
    if (cwd == null || (cwd != '~' && !cwd.startsWith('~/'))) return cwd;
    return cwd.replaceFirst('~', _profile.home);
  }
}
