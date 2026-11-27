import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/notify/push_service.dart';
import 'package:pw_server/src/api/client_session.dart';

/// Отправляет уведомления агента во внешний push-relay.
///
/// Сервис резолвится лениво: DI агента регистрирует [PushService] после
/// регистрации [AppNotifier].
final class PushAppNotifier implements AppNotifier {
  PushAppNotifier(this._service, {this._clientSessions, this.isPaused});

  final PushService Function() _service;
  final ClientSessionRegistry? _clientSessions;

  /// Действует ли сейчас общая пауза уведомлений.
  ///
  /// Проверка читает состояние сервиса внимания, а не настройку с диска:
  /// уведомление приходит на каждый шаг хода, и лишний запрос к базе здесь
  /// не нужен. Колбэк ленивый: при создании демона агент ещё не собран.
  final bool Function()? isPaused;

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
    // Общая пауза выключает уведомления на всех устройствах. Событие не
    // теряется: чат, карточка и непрочитанное остаются, а после паузы
    // приходит один дайджест.
    if (isPaused?.call() ?? false) {
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
