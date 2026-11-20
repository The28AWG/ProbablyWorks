import 'package:pw_agent/agent/domain/chat_models.dart';

/// Элемент очереди: пользовательский промпт или событие (например, фоновая команда завершилась).
class QueuedPrompt {
  const QueuedPrompt.user(
    this.text, {
    this.attachments = const [],
    this.mentions = const [],
    this.note,
  }) : isEvent = false;

  const QueuedPrompt.event(this.text)
    : attachments = const [],
      mentions = const [],
      note = null,
      isEvent = true;

  final String text;
  final List<AttachmentRef> attachments;
  final List<MentionRef> mentions;
  final bool isEvent;

  /// Служебная заметка перед промптом, отдельным событием.
  ///
  /// Так отложенная задача сообщает, что сработала позже срока, не меняя текст,
  /// который написал пользователь.
  final String? note;
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
