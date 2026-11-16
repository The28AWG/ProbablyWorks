import 'package:pw_agent/agent/domain/chat_models.dart';

/// Вложение вместе с сообщением, в котором оно лежит.
final class FoundAttachment {
  const FoundAttachment(this.message, this.attachment);

  final ChatMessage message;
  final AttachmentRef attachment;
}

/// Ищет вложение по имени среди [messages] — сообщений **одного** чата.
///
/// Это общее правило для всех инструментов, которые читают результат чужой
/// работы: источник ищется в наборе, уже ограниченном чатом, а не отдельным
/// запросом по id. Поэтому `message_id` из соседнего чата ничего не откроет:
/// такого сообщения в наборе просто нет.
///
/// Новые сообщения просматриваются первыми: при повторяющемся имени
/// возвращается последнее вложение, а [messageId] уточняет, из какого сообщения.
FoundAttachment? findAttachment(
  Iterable<ChatMessage> messages,
  String name, {
  String? messageId,
}) {
  final ordered = messages.toList();
  for (var i = ordered.length - 1; i >= 0; i--) {
    final message = ordered[i];
    if (messageId != null && message.id != messageId) continue;
    for (final attachment in message.attachments) {
      if (attachment.name == name) return FoundAttachment(message, attachment);
    }
  }
  return null;
}
