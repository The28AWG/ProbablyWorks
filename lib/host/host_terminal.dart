import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:probably_works/core/util/pid_marker_parser.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/process_control.dart';

/// Размер терминала, с которым запускается команда до первого изменения размера из UI.
const defaultTerminalColumns = 120;
const defaultTerminalRows = 30;

/// Терминал команды на Host. Команда выполняется в PTY: видит настоящий TTY нужного размера,
/// поэтому ведёт себя так же, как в консоли (цвета, перенос строк, интерактивные программы).
/// Вывод PTY объединяет stdout и stderr.
abstract interface class HostTerminal {
  /// Вывод PTY в сыром виде (с ANSI). Новый подписчик сначала получает накопленную историю,
  /// затем живые чанки. Поток закрывается, когда процесс завершился.
  Stream<Uint8List> attach();

  /// pid процесса команды. Завершается, когда pid известен; `null`, если Host его не сообщает.
  Future<int?> get pid;

  /// Код выхода процесса. Ошибка означает обрыв соединения.
  Future<int?> get exitCode;

  /// Ввод в PTY (клавиши уже закодированы терминалом). После завершения игнорируется.
  void write(Uint8List data);

  /// Новый размер терминала в колонках и строках. После завершения игнорируется.
  void resize(int columns, int rows);
}

/// Низкоуровневый PTY, который предоставляет конкретный рантайм (local или SSH).
abstract interface class PtyChannel {
  /// Вывод PTY (stdout и stderr объединены).
  Stream<Uint8List> get output;

  /// pid, известный сразу при создании. Для posix pid берётся из маркера в выводе.
  int? get knownPid;

  void write(Uint8List data);

  void resize(int columns, int rows);

  /// Завершение канала. Может завершиться ошибкой при обрыве соединения.
  Future<int?> get exitCode;
}

/// [HostTerminal] поверх [PtyChannel]: хранит историю вывода, разбирает маркеры обёртки
/// (pid и код выхода) и гарантирует, что вывод и код выхода доходят в правильном порядке.
final class PtyHostTerminal implements HostTerminal {
  /// [markers] — обёртка печатает маркеры pid и кода выхода (см. `ProcessControl.wrapTerminal`).
  PtyHostTerminal(this._channel, {required bool markers})
    : _pidParser = markers ? PidMarkerParser() : null,
      _exitScanner = markers ? _ExitMarkerScanner() : null {
    if (!markers) _pid.complete(_channel.knownPid);
    _exit = _channel.exitCode;
    unawaited(_markFinishedWhenExitCompletes());
    _channel.output.listen(
      _onChunk,
      onError: (Object _) => _onDone(),
      onDone: _onDone,
    );
  }

  static const _maxHistoryBytes = 4 * 1024 * 1024;

  /// Подтверждение конца команды: обёртка ждёт его, прежде чем завершиться.
  static final _ack = Uint8List.fromList(const [0x0a]);

  final PtyChannel _channel;
  final PidMarkerParser? _pidParser;
  final _ExitMarkerScanner? _exitScanner;
  final _live = StreamController<Uint8List>.broadcast();
  final _pid = Completer<int?>();
  final _history = ListQueue<Uint8List>();
  var _historyBytes = 0;
  var _outputClosed = false;
  var _finished = false;
  var _acked = false;
  late final Future<int?> _exit;

  @override
  Stream<Uint8List> attach() => Stream.multi((controller) {
    for (final chunk in _history) {
      controller.add(chunk);
    }
    if (_outputClosed) {
      controller.close();
      return;
    }
    final sub = _live.stream.listen(controller.add, onDone: controller.close);
    controller.onCancel = sub.cancel;
  });

  @override
  Future<int?> get pid => _pid.future;

  /// Код из маркера обёртки, если он был; иначе код, который сообщил канал (например, сигнал).
  @override
  Future<int?> get exitCode async {
    try {
      final code = await _exit;
      return _exitScanner?.exitCode ?? code;
    } on Object {
      final marked = _exitScanner?.exitCode;
      if (marked != null) return marked;
      rethrow;
    }
  }

  @override
  void write(Uint8List data) {
    if (_finished) return;
    _channel.write(data);
  }

  @override
  void resize(int columns, int rows) {
    if (_finished) return;
    _channel.resize(columns, rows);
  }

  void _onChunk(Uint8List chunk) {
    final parser = _pidParser;
    var bytes = parser == null ? chunk : parser.add(chunk);
    if (parser?.pid case final pid?) _resolvePid(pid);
    final scanner = _exitScanner;
    if (scanner != null) {
      bytes = scanner.add(bytes);
      if (scanner.exitCode != null && !_acked) {
        _acked = true;
        _channel.write(_ack);
      }
    }
    if (bytes.isEmpty) return;
    _remember(bytes);
    _live.add(bytes);
  }

  void _onDone() {
    if (_outputClosed) return;
    var tail = _pidParser?.flush() ?? Uint8List(0);
    final scanner = _exitScanner;
    if (scanner != null) {
      tail = scanner.add(tail);
      tail = _concat(tail, scanner.flush());
    }
    if (tail.isNotEmpty) {
      _remember(tail);
      _live.add(tail);
    }
    _resolvePid(_pidParser?.pid);
    _outputClosed = true;
    unawaited(_live.close());
  }

  void _resolvePid(int? pid) {
    if (!_pid.isCompleted && pid != null) _pid.complete(pid);
  }

  Future<void> _markFinishedWhenExitCompletes() async {
    try {
      await _exit;
    } on Object {
      // Код выхода недоступен — всё равно считаем сессию завершённой.
    }
    _finished = true;
  }

  /// История ограничена по байтам: самые старые чанки уходят первыми.
  void _remember(Uint8List bytes) {
    _history.add(bytes);
    _historyBytes += bytes.length;
    while (_historyBytes > _maxHistoryBytes && _history.isNotEmpty) {
      _historyBytes -= _history.removeFirst().length;
    }
  }

  static Uint8List _concat(Uint8List a, Uint8List b) {
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return Uint8List.fromList([...a, ...b]);
  }
}

/// Ищет в выводе маркер кода выхода `ESC ] PW;EXIT=<код> BEL` и вырезает его.
/// Байты, которые могут оказаться началом маркера, придерживаются до следующего чанка.
final class _ExitMarkerScanner {
  static final _prefix = Uint8List.fromList(
    utf8.encode(ProcessControl.exitMarkerPrefix),
  );
  static const _bel = 0x07;

  var _pending = Uint8List(0);

  /// Код выхода, когда маркер найден.
  int? exitCode;

  /// Возвращает байты вывода без маркера. Всё после маркера отбрасывается.
  Uint8List add(Uint8List chunk) {
    if (exitCode != null) return Uint8List(0);
    final data = _pending.isEmpty
        ? chunk
        : Uint8List.fromList([..._pending, ...chunk]);
    _pending = Uint8List(0);
    final start = _indexOf(data, _prefix, 0);
    if (start == -1) {
      final keep = _partialPrefixLength(data);
      _pending = Uint8List.sublistView(data, data.length - keep);
      return Uint8List.sublistView(data, 0, data.length - keep);
    }
    final digitsStart = start + _prefix.length;
    final end = data.indexOf(_bel, digitsStart);
    if (end == -1) {
      _pending = Uint8List.sublistView(data, start);
      return Uint8List.sublistView(data, 0, start);
    }
    exitCode = int.tryParse(utf8.decode(data.sublist(digitsStart, end))) ?? -1;
    return Uint8List.sublistView(data, 0, start);
  }

  /// Отдаёт придержанное, если маркер так и не пришёл (например, команда убита).
  Uint8List flush() {
    final rest = _pending;
    _pending = Uint8List(0);
    return rest;
  }

  /// Длина хвоста данных, который совпадает с началом маркера.
  int _partialPrefixLength(Uint8List data) {
    final longest = min(_prefix.length - 1, data.length);
    for (var length = longest; length > 0; length--) {
      var matches = true;
      for (var i = 0; i < length; i++) {
        if (data[data.length - length + i] != _prefix[i]) {
          matches = false;
          break;
        }
      }
      if (matches) return length;
    }
    return 0;
  }

  static int _indexOf(Uint8List data, Uint8List pattern, int from) {
    for (var i = from; i <= data.length - pattern.length; i++) {
      var matches = true;
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          matches = false;
          break;
        }
      }
      if (matches) return i;
    }
    return -1;
  }
}

/// События одного запуска в терминале в той же форме, что и [HostRuntime.run]:
/// pid, вывод и завершение. Вывод не разделяется на stdout и stderr: PTY их объединяет.
Stream<ExecEvent> execEventsOf(HostTerminal terminal) {
  final controller = StreamController<ExecEvent>();
  final outputDone = Completer<void>();
  final output = terminal.attach().listen(
    (bytes) => controller.add(ExecStdout(bytes)),
    onDone: () {
      if (!outputDone.isCompleted) outputDone.complete();
    },
  );
  final pidKnown = () async {
    final pid = await terminal.pid;
    if (pid != null) controller.add(ExecStarted(pid));
  }();
  unawaited(() async {
    int? exitCode;
    var lost = false;
    try {
      exitCode = await terminal.exitCode;
    } on Object {
      lost = true;
    }
    await Future.wait([outputDone.future, pidKnown]);
    await output.cancel();
    controller.add(ExecDone(exitCode: exitCode, connectionLost: lost));
    await controller.close();
  }());
  return controller.stream;
}
