import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/core/notify/notification_action.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/core/logging/app_log.dart';

/// Открывает чат по профилю и id. Вынесено в тип, чтобы сервис не зависел
/// от маршрутизатора напрямую и его можно было проверить без навигации.
typedef ChatOpener = Future<void> Function(String profileId, String chatId);

/// Выполняет действие из системного уведомления: разрешает или отклоняет
/// карточку либо открывает чат.
///
/// Действия подтверждения выполняются только через API профиля. Если карточка
/// уже исчезла (ход завершился, приложение перезапустилось), ошибка не ломает
/// уведомление: пользователь просто увидит чат.
final class NotificationActionService {
  const NotificationActionService({
    required this.profiles,
    required this.openChat,
  });

  final ProfileService profiles;
  final ChatOpener openChat;

  Future<void> handle(NotificationActionRequest request) async {
    await profiles.load();
    final profile = request.profileId == null
        ? profiles.localProfile
        : profiles.byId(request.profileId!);
    if (profile == null) return;

    var resolved = false;
    final approvalId = request.approvalId;
    if (approvalId != null) {
      final api = profiles.agentApiFor(profile);
      try {
        switch (request.action) {
          case NotificationActionKind.approve:
            await api.resolveApproval(approvalId, ApprovalAction.allowOnce);
            resolved = true;
          case NotificationActionKind.deny:
            await api.resolveApproval(approvalId, ApprovalAction.deny);
            resolved = true;
          case NotificationActionKind.open:
            break;
        }
      } on Object catch (error) {
        AppLog.root.warning('notification approval failed', error);
      }
    }

    final chatId = request.chatId;
    if (resolved || chatId == null) return;
    try {
      await openChat(profile.id, chatId);
    } on Object catch (error) {
      AppLog.root.warning('notification chat open failed', error);
    }
  }
}
