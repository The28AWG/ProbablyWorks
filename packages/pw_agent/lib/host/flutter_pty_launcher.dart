import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/host/host_terminal.dart';
import 'package:pw_agent/host/pty_launcher.dart';

/// PTY через flutter_pty2 (C): настоящий TTY на Linux, macOS, Android и
/// Windows (ConPTY).
///
/// Пакет собирает нативную библиотеку build hook-ом и отдаёт её как dynamic
/// code asset, поэтому одинаково работает в Flutter-приложении и в демоне,
/// собранном через `dart build cli`.
///
/// На iOS этот launcher не используется: там нет локального Host, а песочница
/// не разрешает порождать shell-процессы. На Windows PTY пока не включён
/// (см. `LocalHostRuntime.hasTerminal`).
@LazySingleton(as: PtyLauncher)
final class FlutterPtyLauncher implements PtyLauncher {
  /// Создаёт launcher без состояния: настройки приходят в [start].
  const FlutterPtyLauncher();

  @override
  Future<PtyChannel> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required int columns,
    required int rows,
  }) async {
    final PtySession session;
    try {
      session = await Pty.spawn(
        PtySpawnOptions(
          executable: executable,
          arguments: arguments,
          environment: PtyEnvironment.replace(environment),
          size: PtySize(columns: columns, rows: rows),
        ),
      );
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(
        HostFailure(error.toString(), kind: HostFailureKind.spawnFailed),
        stack,
      );
    }
    return _SessionPtyChannel(session);
  }
}

/// Канал поверх [PtySession]: отдаёт вывод потоком и закрывает сессию после
/// завершения процесса.
final class _SessionPtyChannel implements PtyChannel {
  _SessionPtyChannel(this._session) {
    _exitCode = _completeExit();
  }

  final PtySession _session;

  /// Завершается после выхода процесса и доставки всего вывода.
  late final Future<int?> _exitCode;

  var _closed = false;

  @override
  Stream<Uint8List> get output => _session.output;

  @override
  int? get knownPid => _session.pid;

  @override
  Future<int?> get exitCode => _exitCode;

  @override
  void write(Uint8List data) {
    if (_closed) return;
    try {
      // Пишем без ожидания, как старый канал: порядок байтов гарантирует
      // flutter_pty2. Сбой ввода виден по коду выхода процесса.
      unawaited(
        _session.input.write(data).catchError((Object _) {
          return;
        }),
      );
    } on Object {
      // Процесс уже завершился: запись больше не нужна.
    }
  }

  @override
  void resize(int columns, int rows) {
    if (_closed) return;
    try {
      _session.resize(PtySize(columns: columns, rows: rows));
    } on Object {
      // PTY уже закрыт: терминал продолжает работать до получения кода выхода.
    }
  }

  /// Дожидается выхода процесса, закрывает сессию и возвращает код.
  ///
  /// [PtySession.done] завершается только после доставки всего вывода,
  /// поэтому буфер PTY не теряется. Сигнал не имеет числового кода выхода:
  /// возвращаем null, как раньше делал `tryWait()` у portable_pty.
  Future<int?> _completeExit() async {
    try {
      final exit = await _session.done;
      return switch (exit) {
        PtyExitCode(:final code) => code,
        PtySignalExit() => null,
      };
    } finally {
      _closed = true;
      try {
        await _session.close();
      } on Object {
        // Сессия уже закрыта или процесс завершился: повторное закрытие не нужно.
      }
    }
  }
}
