import 'dart:convert';

/// Инкрементальный UTF-8 декодер: многобайтовый символ, разрезанный между
/// чанками, не превращается в мусор.
class Utf8ChunkDecoder {
  Utf8ChunkDecoder() {
    _input = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_Sink(_out));
  }

  final StringBuffer _out = StringBuffer();
  late final ByteConversionSink _input;

  /// Добавляет байты и возвращает декодированный текст, готовый к выводу.
  String add(List<int> bytes) {
    _input.add(bytes);
    return _take();
  }

  /// Завершает декодирование; незакрытый хвост превращается в U+FFFD.
  String close() {
    _input.close();
    return _take();
  }

  String _take() {
    final text = _out.toString();
    _out.clear();
    return text;
  }
}

class _Sink implements Sink<String> {
  _Sink(this._buffer);

  final StringBuffer _buffer;

  @override
  void add(String data) => _buffer.write(data);

  @override
  void close() {
    return;
  }
}
