import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:path/path.dart' as p;
import 'package:pw_agent/core/security/file_permissions.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/core/util/redactor.dart';

/// Файлы логов запусков — временный буфер на время выполнения.
/// После финала в SQLite (`output_text`) переносится только хвост вывода, файл
/// удаляется: полный лог не хранится, как и в терминале, где старые строки
/// вытесняются новыми.
class ExecLogStore {
  ExecLogStore(this.rootDir);

  /// Корень данных приложения; логи лежат в `<root>/chats/<chatId>/runs/<toolCallId>.log`.
  final Directory rootDir;

  /// Сколько последних символов живого вывода держится в памяти для модели.
  /// Это только подсказка «что уже происходит»: полный хвост появится в БД
  /// после финала, а держать больше не нужно — контекст модели ограничен.
  static const _liveTailChars = 64 * 1024;

  final Map<String, IOSink> _sinks = {};
  final Map<String, StringBuffer> _liveTails = {};

  Directory runsDir(String chatId) =>
      Directory(p.join(rootDir.path, 'chats', chatId, 'runs'));

  String logPath(String chatId, String toolCallId) =>
      p.join(runsDir(chatId).path, '$toolCallId.log');

  /// Открывает файл лога перед стартом команды.
  Future<String> open(String chatId, String toolCallId) async {
    _liveTails.remove(toolCallId);
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

  /// Дописывает чанк (с редакцией секретов). Файл пишется через буферизованный
  /// [IOSink]; читать идущий запуск нужно из [liveTail], а не с диска.
  void append(String toolCallId, String text) {
    final sink = _sinks[toolCallId];
    if (sink == null) return;
    sink.write(Redactor.redact(text));
    final live = _liveTails.putIfAbsent(toolCallId, StringBuffer.new)
      ..write(text);
    if (live.length > _liveTailChars * 2) {
      final tail = charSuffix(live.toString(), _liveTailChars);
      live
        ..clear()
        ..write(tail);
    }
  }

  /// Последние символы вывода идущего запуска. null — запуск ещё ничего не писал.
  String? liveTail(String toolCallId) => _liveTails[toolCallId]?.toString();

  /// Освобождает живой хвост: после финала вывод читается из БД.
  void dropLiveTail(String toolCallId) => _liveTails.remove(toolCallId);

  Future<void> closeSink(String toolCallId) async {
    final sink = _sinks.remove(toolCallId);
    await sink?.flush();
    await sink?.close();
  }

  /// Переносит лог в `output_text` и удаляет файл. Хранится только конец:
  /// старые строки вытесняются, как в терминале. Память ограничена [maxBytes]:
  /// большой файл не читается целиком, берётся хвост (через seek).
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
        await raf.setPosition(size - maxBytes);
        final tail = utf8.decode(
          await raf.read(maxBytes),
          allowMalformed: true,
        );
        // Срез проходит по байтам и может попасть в середину строки или
        // многобайтового символа. Отбрасываем неполную первую строку, чтобы
        // хвост начинался с целой: так же ведёт себя терминал.
        final chars = tail.characters;
        final firstBreak = chars.takeWhile((char) => char != '\n').length;
        text = firstBreak + 1 < chars.length
            ? charRange(tail, firstBreak + 1, chars.length)
            : tail;
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
