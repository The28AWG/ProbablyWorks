/// Потоки ввода-вывода команд виртуального shell: приёмники stdout и stderr, файлы перенаправлений,
/// буферы конвейера и общий бюджет вывода запуска.
///
/// Всё работает в памяти и синхронно: команды пишут байты в приёмник, а итог собирается в события
/// [ExecEvent] в порядке записи. Так stdout и stderr сохраняют взаимный порядок, как в терминале.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/virtual/vfs_path.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';

/// Приёмник байтов команды: stdout, stderr, файл или буфер конвейера.
abstract interface class ShellSink {
  /// Принимает байты. Приёмник может отбросить лишнее (лимит), но не бросает исключений.
  void write(Uint8List bytes);
}

extension ShellSinkText on ShellSink {
  /// Записывает текст в UTF-8.
  void writeText(String text) => write(Uint8List.fromList(utf8.encode(text)));
}

/// Общий бюджет вывода одного запуска. Исчерпание не прерывает команду: лишние байты отбрасываются,
/// а запуск помечается как усечённый, чтобы интерпретатор сказал об этом явно.
final class OutputBudget {
  OutputBudget(this._remaining);

  int _remaining;

  /// Был ли отброшен хотя бы один байт.
  bool truncated = false;

  /// Сколько из [wanted] байт вошло в бюджет. Остальное отмечается как усечение.
  int take(int wanted) {
    final allowed = wanted < _remaining ? wanted : _remaining;
    _remaining -= allowed;
    if (allowed < wanted) truncated = true;
    return allowed;
  }
}

/// Приёмник, который отдаёт байты как события запуска. Stdout и stderr различаются типом события.
/// [onEvent] вызывается сразу при записи: подписчик видит вывод до конца команды и может отменить запуск.
final class EventSink implements ShellSink {
  EventSink(
    this._events, {
    required this.isStderr,
    required this.budget,
    this.onEvent,
  });

  final List<ExecEvent> _events;
  final bool isStderr;
  final OutputBudget budget;
  final void Function(ExecEvent event)? onEvent;

  @override
  void write(Uint8List bytes) {
    final allowed = budget.take(bytes.length);
    if (allowed == 0) return;
    // Копия: отправитель может переиспользовать свой буфер после записи.
    final chunk = Uint8List.fromList(bytes.sublist(0, allowed));
    final event = isStderr ? ExecStderr(chunk) : ExecStdout(chunk);
    _events.add(event);
    onEvent?.call(event);
  }
}

/// Буфер между стадиями конвейера и для подстановки `$(...)`. Ограничен [limit] байтами,
/// лишнее отбрасывается и помечается в [truncated].
final class BufferSink implements ShellSink {
  BufferSink(this._limit);

  final int _limit;
  final BytesBuilder _bytes = BytesBuilder();

  /// Был ли отброшен хотя бы один байт сверх лимита.
  bool truncated = false;

  @override
  void write(Uint8List bytes) {
    final room = _limit - _bytes.length;
    if (room <= 0) {
      if (bytes.isNotEmpty) truncated = true;
      return;
    }
    if (bytes.length > room) {
      truncated = true;
      _bytes.add(bytes.sublist(0, room));
      return;
    }
    _bytes.add(bytes);
  }

  /// Накопленные байты. Вызывать после того, как писатель закончил работу.
  Uint8List get bytes => _bytes.toBytes();
}

/// Вход команды: байты и позиция чтения. Один объект разделяется всеми командами одного места, поэтому
/// `read` в `while read ...; done < file` на каждой итерации продолжает с того места, где остановился.
final class ShellInput {
  ShellInput(this.bytes);

  final Uint8List bytes;
  int _offset = 0;

  /// Забирает весь оставшийся вход, как `cat`. Повторный вызов вернёт пустой массив.
  Uint8List takeRest() {
    final rest = Uint8List.fromList(bytes.sublist(_offset));
    _offset = bytes.length;
    return rest;
  }

  /// Следующая строка без перевода строки. [terminated] — false, если вход кончился без `\n`.
  /// null — вход исчерпан.
  ({String text, bool terminated})? readLine() {
    if (_offset >= bytes.length) return null;
    var end = _offset;
    while (end < bytes.length && bytes[end] != 0x0a) {
      end++;
    }
    final text = utf8.decode(bytes.sublist(_offset, end), allowMalformed: true);
    final terminated = end < bytes.length;
    _offset = terminated ? end + 1 : end;
    return (text: text, terminated: terminated);
  }

  /// До [count] байт, не дожидаясь перевода строки (`read -n`).
  /// null — вход уже кончился. [full] — прочитано ровно [count] байт; иначе вход кончился раньше.
  ({String text, bool full})? readCount(int count) {
    if (count <= 0 || _offset >= bytes.length) return null;
    final start = _offset;
    final end = start + count;
    final take = end > bytes.length ? bytes.length : end;
    final text = utf8.decode(bytes.sublist(start, take), allowMalformed: true);
    _offset = take;
    return (text: text, full: take - start == count);
  }

  /// Байты до [delimiter], не включая его (`read -d`). [found] — разделитель встретился.
  ({String text, bool found})? readUntil(int delimiter) {
    if (_offset >= bytes.length) return null;
    var end = _offset;
    while (end < bytes.length && bytes[end] != delimiter) {
      end++;
    }
    final found = end < bytes.length;
    final text = utf8.decode(bytes.sublist(_offset, end), allowMalformed: true);
    _offset = found ? end + 1 : end;
    return (text: text, found: found);
  }
}

/// Приёмник, который отбрасывает всё: `/dev/null`. Считает отброшенные байты, чтобы поведение было
/// проверяемым без чтения файла.
final class NullSink implements ShellSink {
  NullSink();

  /// Сколько байт отброшено всего.
  int discarded = 0;

  @override
  void write(Uint8List bytes) => discarded += bytes.length;
}

/// Файл, открытый на запись перенаправлением `>` или `>>`.
///
/// Как в shell, файл очищается (или создаётся) при открытии, даже если команда ничего не напишет.
/// Байты копятся в памяти и записываются в [close], потому что VFS пишет файл целиком и атомарно.
final class FileSink implements ShellSink {
  FileSink._(this._fs, this._path, this._cwd, this._prefix);

  final VirtualFs _fs;
  final String _path;
  final String _cwd;

  /// Содержимое, которое было в файле до открытия (для `>>`); для `>` пусто.
  final Uint8List _prefix;
  final BytesBuilder _data = BytesBuilder();

  /// Открывает [path] от [cwd]. Ошибки VFS (нет каталога, это каталог) пробрасываются сразу, до запуска
  /// команды, как это делает shell.
  static Future<FileSink> open(
    VirtualFs fs,
    String path, {
    required String cwd,
    required bool append,
  }) async {
    if (append) {
      final existing = await fs.stat(path, cwd: cwd);
      if (existing != null) {
        final prefix = await fs.readBytes(path, cwd: cwd);
        return FileSink._(fs, path, cwd, prefix);
      }
    }
    await fs.writeBytes(path, Uint8List(0), cwd: cwd);
    return FileSink._(fs, path, cwd, Uint8List(0));
  }

  /// Путь файла, как его указали в перенаправлении (для сообщений об ошибках).
  String get path => _path;

  @override
  void write(Uint8List bytes) => _data.add(bytes);

  /// Записывает накопленное в файл. Ошибка VFS (лимит размера, квота) пробрасывается вызывающему.
  Future<void> close() async {
    if (_data.isEmpty) return;
    final content = BytesBuilder()
      ..add(_prefix)
      ..add(_data.toBytes());
    await _fs.writeBytes(_path, content.toBytes(), cwd: _cwd);
  }
}

/// Путь `/dev/null` относительно [cwd]: перенаправления в него не трогают VFS.
bool isDevNull(String path, String cwd) =>
    VfsPath.normalize(path, cwd: cwd) == '/dev/null';
