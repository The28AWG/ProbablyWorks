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
    String? questionId,
    String? noticeId,
  }) {
    // Push не нужен только там, где пользователь действительно смотрит чат:
    // открытое, но давно забытое окно больше не подавляет уведомление. Конец
    // ленты тоже важен: при прокрутке вверх новое сообщение ещё не видно.
    if (_clientSessions?.hasVisibleChat(chatId) ?? false) {
      return Future<void>.value();
    }
    // Общая пауза выключает уведомления на всех устройствах. Событие не
    // теряется: чат, карточка и непрочитанное остаются, а после паузы
    // приходит один дайджест.
    if (isPaused?.call() ?? false) {
      return Future<void>.value();
    }
    return _service().notify(
      kind: kind,
      chatTitle: chatTitle,
      detail: detail,
      profileId: profileId,
      chatId: chatId,
      approvalId: approvalId,
      questionId: questionId,
      noticeId: noticeId,
    );
  }

  /// Отменяет уведомление в relay по устойчивому ключу.
  ///
  /// Карточку могли закрыть на любом устройстве; отмена уходит туда же, куда
  /// исходное событие, и снимает ровно его. Если push не настроен или relay
  /// недоступен, ошибка не ломает ход: устаревшая строка просто останется до
  /// следующего действия с карточкой.
  @override
  Future<void> cancel(String noticeId) => _service().cancel(noticeId);

  /// Бейдж рисует устройство-получатель по полю `badge` в push payload.
  /// У сервера нет своей иконки, поэтому здесь обновлять нечего.
  @override
  Future<void> setUnreadCount(int count) => Future<void>.value();
}
