import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:probably_works/core/security/file_permissions.dart';
import 'package:probably_works/core/util/redactor.dart';

/// Файлы логов запусков — временный буфер на время выполнения.
/// После финала содержимое переносится в SQLite (`output_text`) и файл удаляется.
class ExecLogStore {
  ExecLogStore(this.rootDir);

  /// Корень данных приложения; логи лежат в `<root>/chats/<chatId>/runs/<toolCallId>.log`.
  final Directory rootDir;

  final Map<String, IOSink> _sinks = {};

  Directory runsDir(String chatId) =>
      Directory(p.join(rootDir.path, 'chats', chatId, 'runs'));

  String logPath(String chatId, String toolCallId) =>
      p.join(runsDir(chatId).path, '$toolCallId.log');

  /// Открывает файл лога перед стартом команды.
  Future<String> open(String chatId, String toolCallId) async {
    final path = logPath(chatId, toolCallId);
    final dir = Directory(p.dirname(path));
    final createdDir = !dir.existsSync();
    await dir.create(recursive: true);
    if (createdDir) FilePermissions.directory(dir);
    final file = File(path);
    final createdFile = !file.existsSync();
    if (createdFile) file.createSync(recursive: true);
    if (createdFile) FilePermissions.file(file);
    _sinks[toolCallId] = file.openWrite(mode: FileMode.write);
    return path;
  }

  /// Дописывает чанк (с редакцией секретов). Сброс на диск — раз в запись.
  void append(String toolCallId, String text) {
    final sink = _sinks[toolCallId];
    if (sink == null) return;
    sink.write(Redactor.redact(text));
  }

  Future<void> closeSink(String toolCallId) async {
    final sink = _sinks.remove(toolCallId);
    await sink?.flush();
    await sink?.close();
  }

  /// Переносит лог в `output_text` и удаляет файл. Память ограничена [maxBytes]:
  /// большой файл не читается целиком, берутся только голова и хвост (через seek).
  /// Возвращает текст и флаг усечения.
  Future<({String text, bool truncated})> compactToDb(
    String path, {
    required int maxBytes,
  }) async {
    final file = File(path);
    if (!file.existsSync()) return (text: '', truncated: false);
    final size = await file.length();
    final raf = await file.open();
    final String text;
    final bool truncated;
    try {
      if (size <= maxBytes) {
        text = utf8.decode(await raf.read(size), allowMalformed: true);
        truncated = false;
      } else {
        final head = (maxBytes * 0.6).floor();
        final tail = maxBytes - head;
        await raf.setPosition(0);
        final headText = utf8.decode(
          await raf.read(head),
          allowMalformed: true,
        );
        await raf.setPosition(size - tail);
        final tailText = utf8.decode(
          await raf.read(tail),
          allowMalformed: true,
        );
        text = '$headText\n…[truncated ${size - maxBytes} bytes]…\n$tailText';
        truncated = true;
      }
    } finally {
      await raf.close();
    }
    await file.delete();
    return (text: text, truncated: truncated);
  }

  Future<void> deleteFile(String? path) async {
    if (path == null) return;
    final file = File(path);
    if (file.existsSync()) await file.delete();
  }

  Future<void> deleteChat(String chatId) async {
    final dir = Directory(p.join(rootDir.path, 'chats', chatId));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// GC: удаляет файлы логов, на которые больше никто не ссылается.
  Future<int> gcUnreferenced(Set<String> referencedPaths) async {
    final chatsDir = Directory(p.join(rootDir.path, 'chats'));
    if (!chatsDir.existsSync()) return 0;
    var removed = 0;
    await for (final entity in chatsDir.list(recursive: true)) {
      if (entity is File &&
          entity.path.endsWith('.log') &&
          !referencedPaths.contains(entity.path)) {
        await entity.delete();
        removed++;
      }
    }
    return removed;
  }
}
