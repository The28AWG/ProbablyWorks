import 'package:pw_agent/core/notify/app_notifier.dart';

/// Web-клиент не показывает системные уведомления: он подключается к
/// удалённому серверу, а браузерные уведомления не входят в первый срез.
final class WebAppNotifier implements AppNotifier {
  const WebAppNotifier();

  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
  }) => Future<void>.value();
}
