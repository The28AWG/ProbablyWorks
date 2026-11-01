import 'package:probably_works/agent/domain/chat_models.dart';

/// Элемент очереди: пользовательский промпт или событие (например, фоновая команда завершилась).
class QueuedPrompt {
  const QueuedPrompt.user(this.text, {this.attachments = const []})
    : isEvent = false;

  const QueuedPrompt.event(this.text) : attachments = const [], isEvent = true;

  final String text;
  final List<AttachmentRef> attachments;
  final bool isEvent;
}

/// Очередь ввода во время хода агента.
/// Soft drain: элементы вливаются в контекст на границе шага (после батча инструментов).
/// Send now: элемент встаёт в начало очереди, текущий шаг модели прерывается.
class PromptQueue {
  final List<QueuedPrompt> _items = [];

  List<QueuedPrompt> get items => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  bool get isNotEmpty => _items.isNotEmpty;

  void enqueue(QueuedPrompt prompt) => _items.add(prompt);

  void enqueueFirst(QueuedPrompt prompt) => _items.insert(0, prompt);

  /// Забирает все элементы в порядке отправки.
  List<QueuedPrompt> drain() {
    final taken = List<QueuedPrompt>.of(_items);
    _items.clear();
    return taken;
  }

  void remove(int index) => takeAt(index);

  /// Вынимает элемент по индексу; null, если индекс вне диапазона.
  QueuedPrompt? takeAt(int index) =>
      index >= 0 && index < _items.length ? _items.removeAt(index) : null;

  void clear() => _items.clear();
}
