import 'dart:convert';

import 'package:plugin_api/plugin_api.dart';
import 'package:pw_agent/host/read_file_output.dart';

/// Загружает один кусок сырого вывода `read_file` для курсора плагина.
///
/// [first] — первый кусок: вызывающий сам решает, когда закрыть его policy и
/// подтверждением, а когда дочитать тем же разрешением.
typedef ReadFileChunkLoader = Future<({String text, bool isError})> Function(
  int offset,
  int byteOffset,
  bool first,
);

/// Курсор чтения файла плагином.
///
/// Разбирает вывод `read_file` и собирает из него исходный текст: убирает
/// заголовок, номера строк и подвал, склеивает разрезанные строки. Host не
/// отдаёт файл целиком за один вызов, поэтому курсор дочитывает остаток через
/// [next].
///
/// Служебный формат не теряет данные: длина собранного текста сверяется с
/// размером файла из заголовка, поэтому отсутствие завершающего перевода
/// строки восстанавливается точно.
final class ReadFileCursor implements PluginFileReader {
  ReadFileCursor._(this._load);

  final ReadFileChunkLoader _load;

  final _buffer = StringBuffer();
  var _wroteLine = false;
  int? _totalBytes;
  var _offset = 1;
  var _byteOffset = 0;
  var _done = false;
  var _error = false;

  /// Открывает файл и читает первый кусок.
  ///
  /// Загрузчик не должен бросать: сбой Host приходит как [isError], иначе
  /// исключение прервало бы весь вызов инструмента.
  static Future<ReadFileCursor> open(ReadFileChunkLoader load) async {
    final cursor = ReadFileCursor._(load);
    await cursor._read(offset: 1, byteOffset: 0, first: true);
    return cursor;
  }

  @override
  String get text => _buffer.toString();

  @override
  bool get done => _done;

  @override
  bool get isError => _error;

  @override
  Future<void> next() async {
    if (_done) return;
    final offset = _offset;
    final byteOffset = _byteOffset;
    await _read(offset: offset, byteOffset: byteOffset, first: false);
    // Курсор обязан двигаться. Повтор той же позиции означал бы цикл без
    // прогресса: незачем ждать, пока плагин упрётся в лимит хода.
    if (!_done && _offset == offset && _byteOffset == byteOffset) {
      _done = true;
    }
  }

  Future<void> _read({
    required int offset,
    required int byteOffset,
    required bool first,
  }) async {
    final chunk = await _load(offset, byteOffset, first);
    if (chunk.isError) {
      _buffer.write(chunk.text);
      _error = true;
      _done = true;
      return;
    }
    final output = parseReadFileOutput(chunk.text);
    if (output == null || output is ReadFileError) {
      // Формат не совпал или файл нельзя прочитать как текст. Служебный вывод
      // молча не отдаём: плагин должен увидеть ошибку, а не `[file: ...]`.
      _buffer.write(chunk.text);
      _error = true;
      _done = true;
      return;
    }
    _apply(output);
  }

  void _apply(ReadFileOutput output) {
    switch (output) {
      case ReadFileText():
        _totalBytes ??= output.totalBytes;
        for (final line in output.lines) {
          if (line.byteOffset > 0) {
            // Продолжение разрезанной строки: разделитель уже не нужен.
            _buffer.write(line.text);
          } else {
            if (_wroteLine) _buffer.write('\n');
            _buffer.write(line.text);
            _wroteLine = true;
          }
        }
        _applyFooter(output.footer);
      case ReadFileBeyondEnd():
        _totalBytes ??= output.totalBytes;
        _finish();
      case ReadFileError():
        // Недостижимо: ошибку разбирает `_read` до вызова. Нужно для
        // исчерпывающего switch по sealed-иерархии.
        _error = true;
        _finish();
    }
  }

  void _applyFooter(ReadFileFooter? footer) {
    switch (footer) {
      case ReadFileEndOfFile() || null:
        _finish();
      case ReadFileMore(:final offset):
        _offset = offset;
        _byteOffset = 0;
      case ReadFileCut(:final offset, :final byteOffset):
        _offset = offset;
        _byteOffset = byteOffset;
    }
  }

  /// Завершает чтение.
  ///
  /// Файл, оканчивающийся переводом строки, `awk` не отражает последним пустым
  /// куском: возвращаем его, сверяя длину с размером файла из заголовка. Когда
  /// перевод отсутствует, длина совпадает сразу и ничего не добавляется.
  void _finish() {
    if (_done) return;
    _done = true;
    final size = _totalBytes;
    if (size != null && utf8.encode(_buffer.toString()).length == size - 1) {
      _buffer.write('\n');
    }
  }
}
