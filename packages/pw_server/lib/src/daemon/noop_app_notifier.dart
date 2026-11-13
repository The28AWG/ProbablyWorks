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
  }) => Future<void>.value();
}
