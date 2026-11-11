import 'dart:convert';
import 'dart:typed_data';

import 'package:pw_agent/core/util/char_substring.dart';

/// Отделяет первую строку `PW_PID:<pid>`, которую выводит обёртка команды.
///
/// Маркер приходит в stdout первой строкой. До перевода строки байты
/// накапливаются; если маркера нет, накопленное отдаётся как обычный вывод.
class PidMarkerParser {
  static const prefix = 'PW_PID:';
  static const _maxHeadBytes = 64;

  final BytesBuilder _head = BytesBuilder(copy: false);
  bool _finished = false;

  /// PID процесса, если маркер уже распознан.
  int? pid;

  /// Принимает очередной чанк stdout и возвращает байты без маркерной строки.
  Uint8List add(Uint8List chunk) {
    if (_finished) return chunk;
    _head.add(chunk);
    final bytes = _head.toBytes();
    final newline = bytes.indexOf(0x0a);
    if (newline == -1) {
      if (bytes.length < _maxHeadBytes) return Uint8List(0);
      return _finish(bytes);
    }
    final line = utf8.decode(bytes.sublist(0, newline), allowMalformed: true);
    if (!line.startsWith(prefix)) return _finish(bytes);
    pid = int.tryParse(charFrom(line, prefix.length).trim());
    _finished = true;
    _head.clear();
    return Uint8List.sublistView(bytes, newline + 1);
  }

  /// Отдаёт всё, что ещё не вышло наружу (например, если команда завершилась до маркера).
  Uint8List flush() {
    if (_finished) return Uint8List(0);
    return _finish(_head.toBytes());
  }

  Uint8List _finish(Uint8List bytes) {
    _finished = true;
    _head.clear();
    return bytes;
  }
}
