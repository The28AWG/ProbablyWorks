import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:uuid/uuid.dart';

/// Элемент очереди: пользовательский промпт или событие (например, фоновая команда завершилась).
///
/// [id] — устойчивая identity элемента. По ней клиент адресует действие
/// (отправить сейчас, удалить, вернуть в поле ввода), а не по позиции: пока
/// запрос летит, очередь могла измениться в другом окне.
class QueuedPrompt {
  const QueuedPrompt.user(
    this.text, {
    this.id = '',
    this.attachments = const [],
    this.mentions = const [],
    this.note,
  }) : isEvent = false;

  const QueuedPrompt.event(this.text, {this.id = ''})
    : attachments = const [],
      mentions = const [],
      note = null,
      isEvent = true;

  final String id;
  final String text;
  final List<AttachmentRef> attachments;
  final List<MentionRef> mentions;
  final bool isEvent;

  /// Служебная заметка перед промптом, отдельным событием.
  ///
  /// Так отложенная задача сообщает, что сработала позже срока, не меняя текст,
  /// который написал пользователь.
  final String? note;

  /// Копия элемента с назначенной identity.
  QueuedPrompt withId(String value) => isEvent
      ? QueuedPrompt.event(text, id: value)
      : QueuedPrompt.user(
          text,
          id: value,
          attachments: attachments,
          mentions: mentions,
          note: note,
        );
}

/// Очередь ввода во время хода агента.
/// Soft drain: элементы вливаются в контекст на границе шага (после батча инструментов).
/// Send now: элемент встаёт в начало очереди, текущий шаг модели прерывается.
class PromptQueue {
  PromptQueue();

  static const _uuid = Uuid();

  final List<QueuedPrompt> _items = [];

  List<QueuedPrompt> get items => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  bool get isNotEmpty => _items.isNotEmpty;

  /// Ставит элемент в конец. Элемент без id получает сгенерированный id.
  void enqueue(QueuedPrompt prompt) => _items.add(_identified(prompt));

  /// Ставит элемент в начало (send now). Элемент без id получает id.
  void enqueueFirst(QueuedPrompt prompt) =>
      _items.insert(0, _identified(prompt));

  /// Забирает все элементы в порядке отправки.
  List<QueuedPrompt> drain() {
    final taken = List<QueuedPrompt>.of(_items);
    _items.clear();
    return taken;
  }

  /// Вынимает элемент по устойчивому id; null, если элемента уже нет.
  QueuedPrompt? takeById(String id) {
    final index = _items.indexWhere((item) => item.id == id);
    return index < 0 ? null : _items.removeAt(index);
  }

  /// Переставляет элемент с [id] в начало. false — элемента уже нет.
  bool promoteById(String id) {
    final item = takeById(id);
    if (item == null) return false;
    _items.insert(0, item);
    return true;
  }

  void clear() => _items.clear();

  QueuedPrompt _identified(QueuedPrompt prompt) =>
      prompt.id.isEmpty ? prompt.withId(_uuid.v4()) : prompt;
}
