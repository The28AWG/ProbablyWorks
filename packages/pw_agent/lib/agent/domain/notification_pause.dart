import 'package:equatable/equatable.dart';

/// Почему пользователь поставил уведомления на паузу.
///
/// Причина нужна только интерфейсу: она объясняет, какую кнопку нажали.
/// Сервер по ней ничего не решает, но хранит вместе со сроком, чтобы после
/// перезапуска на всех устройствах была видна одна и та же подпись.
enum NotificationPauseReason {
  /// Короткая пауза «не отвлекать», обычно 30 минут.
  focus,

  /// Встреча или созвон.
  meeting,

  /// Пауза до утра: уведомления вернутся после ночи.
  overnight;

  /// Строка из базы. Неизвестное значение читается как [focus]: новая
  /// причина из будущей версии не должна скрывать саму паузу.
  static NotificationPauseReason fromStorage(String? value) {
    for (final reason in values) {
      if (reason.name == value) return reason;
    }
    return focus;
  }
}

/// Общая для всех устройств пауза системных и push-уведомлений.
///
/// События при этом не теряются: входящие, курсор прочтения и карточки
/// продолжают обновляться. По окончании срока сервер собирает один дайджест,
/// а не показывает накопившиеся уведомления по одному.
///
/// Запись одна на агента: повторная пауза двигает срок, а не копит записи.
/// [revision] растёт при каждой записи, чтобы окна отличали свежий снимок от
/// запоздавшего.
final class NotificationPause extends Equatable {
  const NotificationPause({
    required this.until,
    required this.reason,
    required this.revision,
  });

  /// Момент, до которого уведомления молчат. Хранится и сравнивается как
  /// момент времени, без привязки к часовому поясу устройства.
  final DateTime until;

  final NotificationPauseReason reason;

  final int revision;

  /// Действует ли пауза в момент [now]. Просроченная запись до очистки базой
  /// уже не скрывает уведомления: они должны вернуться, даже если таймер
  /// сработал с задержкой.
  bool isActiveAt(DateTime now) => until.isAfter(now);

  @override
  List<Object?> get props => [until, reason, revision];
}
