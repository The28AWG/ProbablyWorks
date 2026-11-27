import 'package:probably_works/core/notify/web_app_badge.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';

/// Web-клиент не показывает системные уведомления: он подключается к
/// удалённому серверу, а браузерные уведомления не входят в первый срез.
/// Бейдж при этом нужен: установленное web-приложение и вкладка показывают
/// общее непрочитанное.
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
    String? questionId,
    String? noticeId,
  }) => Future<void>.value();

  @override
  Future<void> cancel(String noticeId) => Future<void>.value();

  @override
  Future<void> setUnreadCount(int count) => setWebAppBadge(count);
}
