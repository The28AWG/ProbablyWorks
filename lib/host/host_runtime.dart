import 'dart:typed_data';

import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/host/process_control.dart';

/// События одного запуска команды на Host.
sealed class ExecEvent {
  const ExecEvent();
}

/// Процесс запущен. [pid] — pid процесса команды на Host (local или remote).
final class ExecStarted extends ExecEvent {
  const ExecStarted(this.pid);

  final int pid;
}

/// Сырые байты stdout (UTF-8 декодируется инкрементально потребителем).
final class ExecStdout extends ExecEvent {
  const ExecStdout(this.bytes);

  final Uint8List bytes;
}

final class ExecStderr extends ExecEvent {
  const ExecStderr(this.bytes);

  final Uint8List bytes;
}

/// Команда завершилась. Причина сбоя отличается от кода выхода.
final class ExecDone extends ExecEvent {
  const ExecDone({
    this.exitCode,
    this.connectionLost = false,
    this.spawnFailed = false,
    this.message,
  });

  final int? exitCode;
  final bool connectionLost;
  final bool spawnFailed;
  final String? message;
}

/// Исполнение на Host. Два входа: типизированные операции [perform] (файлы, listing, поиск) и
/// свободная строка [run] (только `run_command`, которую написала модель). Остановка — команда (kill)
/// для реальных хостов; у виртуального Host процессов нет.
abstract interface class HostRuntime {
  HostOs get os;

  /// Есть ли у Host PTY-терминал. Виртуальный Host терминала не имеет: `run_command` идёт в нём через
  /// [run], а [openTerminal] бросает [HostFailure]. Без этого флага вызывающий код попал бы в тупик.
  bool get hasTerminal;

  /// Выполняет типизированную операцию и отдаёт события в том же формате, что и [run].
  /// Реальный Host компилирует операцию в команду, виртуальный выполняет её над своей файловой системой.
  Stream<ExecEvent> perform(HostOp op, {String? cwd, Uint8List? stdin});

  /// Запускает [command] и отдаёт поток событий. Отписка от потока НЕ останавливает процесс.
  /// Для служебных команд: stdout и stderr разделены, TTY нет.
  /// [stdin] — байты, которые передаются процессу на stdin и затем закрывают его ввод (EOF).
  /// Так передаётся содержимое файла: оно не попадает в командную строку и не ограничено её длиной.
  Stream<ExecEvent> run(String command, {String? cwd, Uint8List? stdin});

  /// Запускает [command] в PTY-терминале Host: команда видит настоящий TTY размера
  /// [columns]×[rows]. Размер меняется через [HostTerminal.resize]. Бросает [HostFailure],
  /// если запуск не удался.
  Future<HostTerminal> openTerminal(
    String command, {
    String? cwd,
    int columns = defaultTerminalColumns,
    int rows = defaultTerminalRows,
  });
}

extension HostRuntimeKill on HostRuntime {
  /// Остановка процесса — это обычная команда на Host (`kill`), без отдельного API.
  Future<void> killProcess(int pid, {bool force = false}) async {
    await run(ProcessControl(os).killCommand(pid, force: force)).drain<void>();
  }
}
