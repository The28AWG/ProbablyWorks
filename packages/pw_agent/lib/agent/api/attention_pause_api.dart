import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/notification_pause.dart';

/// Общая пауза уведомлений («тихие часы»).
///
/// Отдельный интерфейс, как snooze и дайджест: старые серверы не знают
/// маршрута паузы, и клиент должен скрыть действие, а не получить ошибку
/// экрана. Встроенный агент реализует интерфейс поверх
/// `ChatAttentionService`, удалённый — поверх `PUT/DELETE /attention/pause`
/// и SSE `chatStatusChanged`/`notificationDigestDue`.
abstract interface class AttentionPauseApi {
  /// Умеет ли подключённый агент ставить уведомления на паузу.
  ///
  /// Новый сервер присылает в снимке входящих поле `pause`, даже когда паузы
  /// нет. Старый поля не присылает, поэтому до первого снимка и после ответа
  /// об отсутствии маршрута значение false.
  bool get supportsPause;

  /// Ставит уведомления на паузу до [until].
  ///
  /// Срок считает клиент в своей локальной зоне: «до утра» означает утро там,
  /// где сидит пользователь. Сервер отклоняет срок в прошлом.
  Future<void> pauseNotifications(
    DateTime until, {
    NotificationPauseReason reason = NotificationPauseReason.focus,
  });

  /// Снимает паузу раньше срока. Идемпотентно.
  Future<void> resumeNotifications();

  /// Дайджест, собранный к окончанию автоматической паузы.
  ///
  /// Событие, а не часть снимка: снимок уже показывает, что пауза снята, а
  /// это событие объясняет, что накопилось, и позволяет показать одно
  /// уведомление вместо пачки запоздавших.
  Stream<AttentionDigest> get pauseDigestDue;
}
