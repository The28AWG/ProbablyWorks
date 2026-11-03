import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:injectable/injectable.dart';
import 'package:portable_pty/portable_pty.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/host/pty_launcher.dart';

/// PTY через portable_pty (Rust): настоящий TTY на Linux, macOS, Windows (ConPTY) и Android.
///
/// Чтение: `readSync` блокирующий, а пакет держит slave открытым до `close()`, поэтому после выхода
/// команды блокирующее чтение не получит EOF, и закрыть PTY безопасно нельзя. Поэтому master переводится
/// в неблокирующий режим, а вывод собирается опросом по таймеру в главном изоляте. Все вызовы PTY идут
/// из одного изолята, гонок с Rust-стороной нет.
@LazySingleton(as: PtyLauncher)
final class PortablePtyLauncher implements PtyLauncher {
  const PortablePtyLauncher();

  @override
  Future<PtyChannel> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required int columns,
    required int rows,
  }) async {
    final PortablePty pty;
    try {
      pty = PortablePty.open(rows: rows, cols: columns)
        ..spawn(executable, args: arguments, environment: environment);
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(
        HostFailure(error.toString(), kind: HostFailureKind.spawnFailed),
        stack,
      );
    }
    if (!_setNonBlocking(pty.masterFd)) {
      pty.close();
      throw const HostFailure(
        'PTY master cannot be set to non-blocking mode',
        kind: HostFailureKind.spawnFailed,
      );
    }
    return _PollingPtyChannel(pty);
  }
}

/// Интервал опроса вывода. Короче — отзывчивее терминал, длиннее — меньше нагрузка на CPU.
const _pollInterval = Duration(milliseconds: 15);

/// Размер одного чтения из PTY.
const _readChunk = 8192;

/// Канал поверх [PortablePty]: опрос вывода и кода выхода по таймеру, буферизованный ввод.
final class _PollingPtyChannel implements PtyChannel {
  _PollingPtyChannel(this._pty) {
    _timer = Timer.periodic(_pollInterval, (_) => _tick());
  }

  final PortablePty _pty;
  final _output = StreamController<Uint8List>();
  final _exit = Completer<int?>();
  final List<int> _outbox = [];
  late final Timer _timer;
  var _closed = false;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  int? get knownPid {
    final pid = _pty.childPid;
    return pid > 0 ? pid : null;
  }

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  void write(Uint8List data) {
    if (_closed) return;
    _outbox.addAll(data);
    _flush();
  }

  @override
  void resize(int columns, int rows) {
    if (_closed) return;
    try {
      _pty.resize(rows: rows, cols: columns);
    } on StateError {
      // Размер не изменился: PTY уже закрыт или ресайз отклонён ОС. Терминал продолжает работать.
    }
  }

  void _tick() {
    if (_closed) return;
    _flush();
    _drain();
    final code = _pollExit();
    if (code == null) return;
    // Процесс уже завершился: забираем то, что успело попасть в буфер PTY до выхода.
    _drain();
    _finish(code);
  }

  /// Читает всё, что готово сейчас. Отрицательный результат (нет данных, EAGAIN) приходит как StateError.
  void _drain() {
    while (!_closed) {
      final Uint8List chunk;
      try {
        chunk = _pty.readSync(_readChunk);
      } on StateError {
        return;
      }
      if (chunk.isEmpty) return;
      _output.add(chunk);
    }
  }

  /// Код выхода, если процесс завершился; иначе null.
  int? _pollExit() {
    try {
      return _pty.tryWait();
    } on StateError {
      return null;
    }
  }

  void _flush() {
    while (_outbox.isNotEmpty && !_closed) {
      final take = _outbox.length < _readChunk ? _outbox.length : _readChunk;
      final int written;
      try {
        written = _pty.writeBytes(Uint8List.fromList(_outbox.sublist(0, take)));
      } on StateError {
        return;
      }
      if (written <= 0) return;
      _outbox.removeRange(0, written);
    }
  }

  void _finish(int? code) {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
    _pty.close();
    _exit.complete(code);
    unawaited(_output.close());
  }
}

// fcntl для неблокирующего режима master-fd. Вызов вариативный: в Dart FFI передаётся через VarArgs.
typedef _FcntlNative = Int32 Function(
  Int32 fd,
  Int32 cmd,
  VarArgs<(Int32,)> arg,
);
typedef _FcntlDart = int Function(int fd, int cmd, int arg);

const _fGetFl = 3;
const _fSetFl = 4;

/// O_NONBLOCK различается: 0x0800 на Linux и Android, 0x0004 на macOS и BSD.
final int _oNonBlock = Platform.isMacOS ? 0x0004 : 0x0800;

/// Переводит fd в неблокирующий режим. Возвращает false, если fd не поддерживает флаг (например, -1 на Windows).
bool _setNonBlocking(int fd) {
  if (fd < 0) return false;
  final fcntl = DynamicLibrary.process()
      .lookupFunction<_FcntlNative, _FcntlDart>('fcntl');
  final flags = fcntl(fd, _fGetFl, 0);
  if (flags < 0) return false;
  return fcntl(fd, _fSetFl, flags | _oNonBlock) >= 0;
}
