import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/notify/push_service.dart';
import 'package:pw_server/src/api/client_session.dart';

/// Отправляет уведомления агента во внешний push-relay.
///
/// Сервис резолвится лениво: DI агента регистрирует [PushService] после
/// регистрации [AppNotifier].
final class PushAppNotifier implements AppNotifier {
  PushAppNotifier(this._service, {this._clientSessions});

  final PushService Function() _service;
  final ClientSessionRegistry? _clientSessions;

  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
    String? noticeId,
  }) {
    // Если чат открыт и в фокусе, пользователь уже видит событие. Push нужен
    // только когда все клиенты свернуты или закрыты.
    if (_clientSessions?.hasFocusedChat(chatId) ?? false) {
      return Future<void>.value();
    }
    return _service().notify(kind: kind, chatTitle: chatTitle, detail: detail);
  }

  /// Relay пока не принимает отмену уведомлений: у него нет адресации по
  /// устройству. Локальная отмена карточки не должна ломать ход, поэтому здесь
  /// операция ничего не делает. Когда появятся device-токены, отмена станет
  /// частью того же контракта.
  @override
  Future<void> cancel(String noticeId) => Future<void>.value();
}
