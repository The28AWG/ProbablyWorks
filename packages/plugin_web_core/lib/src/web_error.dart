/// Ошибка веб-инструмента с машинным кодом.
///
/// Код видит модель, [message] и [hint] — человек и модель. Тексты на
/// английском, потому что они уходят в контекст LLM; интерфейс плагина
/// локализует свои сообщения отдельно.
final class WebToolException implements Exception {
  const WebToolException(this.code, this.message, {this.hint});

  final String code;
  final String message;
  final String? hint;

  /// Текст результата инструмента. Формат стабилен: код, сообщение, подсказка.
  String format() {
    final lines = ['error: $code', 'message: $message'];
    if (hint != null && hint!.isNotEmpty) lines.add('hint: $hint');
    return lines.join('\n');
  }

  @override
  String toString() => 'WebToolException($code): $message';
}
