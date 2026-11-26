import 'package:pw_agent/agent/domain/chat_attention.dart';

/// Входящие: сводка решений и проблем по всем чатам.
///
/// Отдельный интерфейс, а не расширение [AgentApi]: старые клиенты и
/// тестовые реализации не должны ломаться из-за нового экрана. Встроенный
/// агент реализует его поверх `AgentHub`, удалённый — поверх `GET /attention`
/// и SSE `chatStatusChanged`.
abstract interface class AttentionApi {
  /// Полный снимок входящих.
  Future<AttentionSnapshot> attention();

  /// Снимки, которые приходят без запроса: изменение карточек, хода,
  /// курсора прочтения или проблемного завершения.
  Stream<AttentionSnapshot> get attentionChanges;

  /// Убирает проблемное завершение хода из входящих, не начиная новый.
  ///
  /// Карточки и непрочитанное так не снимаются: решение по ним принимается
  /// явно, а чтение двигает курсор отдельным действием.
  Future<void> dismissAttention(String chatId);
}
