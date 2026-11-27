import 'package:pw_agent/core/notify/app_notifier.dart';

/// Демону не нужны системные уведомления: события идут в API и журнал.
final class NoopAppNotifier implements AppNotifier {
  const NoopAppNotifier();

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

  /// У демона нет ни иконки, ни вкладки браузера.
  @override
  Future<void> setUnreadCount(int count) => Future<void>.value();
}
