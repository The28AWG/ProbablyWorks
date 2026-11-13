import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/notify/push_service.dart';

/// Отправляет уведомления агента во внешний push-relay.
///
/// Сервис резолвится лениво: DI агента регистрирует [PushService] после
/// регистрации [AppNotifier].
final class PushAppNotifier implements AppNotifier {
  PushAppNotifier(this._service);

  final PushService Function() _service;

  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
  }) => _service().notify(kind: kind, chatTitle: chatTitle, detail: detail);
}
