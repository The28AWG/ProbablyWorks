import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/chat_snooze_menu.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/notification_pause.dart';

/// Действия меню паузы уведомлений.
///
/// Набор намеренно короткий, как у «напомнить позже»: произвольная дата
/// превращала бы быструю кнопку в календарь. [resume] отдельное действие, а
/// не отсутствие выбора, иначе закрытие меню снимало бы паузу.
enum NotificationPauseChoice {
  focus(NotificationPauseReason.focus),
  meeting(NotificationPauseReason.meeting),
  overnight(NotificationPauseReason.overnight),
  resume(null);

  const NotificationPauseChoice(this.reason);

  /// Причина для сервера. Null только у [resume].
  final NotificationPauseReason? reason;

  /// Момент окончания паузы для [now] в локальной зоне.
  ///
  /// Считает клиент: «до утра» — это утро там, где сидит пользователь, а на
  /// сервере может быть другой часовой пояс. Null у [resume].
  DateTime? deadline(DateTime now) => switch (this) {
    NotificationPauseChoice.focus => now.add(const Duration(minutes: 30)),
    NotificationPauseChoice.meeting => now.add(const Duration(hours: 1)),
    NotificationPauseChoice.overnight => _nextMorning(now),
    NotificationPauseChoice.resume => null,
  };
}

/// Следующее утро в 08:00 локального времени.
DateTime _nextMorning(DateTime now) {
  final local = now.toLocal();
  final morning = DateTime(local.year, local.month, local.day, 8);
  if (morning.isAfter(local)) return morning;
  return DateTime(local.year, local.month, local.day + 1, 8);
}

/// Название действия в меню и на кнопке.
String notificationPauseChoiceLabel(
  AppLocalizations l10n,
  NotificationPauseChoice choice,
) => switch (choice) {
  NotificationPauseChoice.focus => l10n.settingsPauseFocus,
  NotificationPauseChoice.meeting => l10n.settingsPauseMeeting,
  NotificationPauseChoice.overnight => l10n.settingsPauseOvernight,
  NotificationPauseChoice.resume => l10n.notificationPauseResume,
};

/// Короткая причина действующей паузы для подписи на всех устройствах.
String notificationPauseReasonLabel(
  AppLocalizations l10n,
  NotificationPauseReason reason,
) => switch (reason) {
  NotificationPauseReason.focus => l10n.notificationPauseReasonFocus,
  NotificationPauseReason.meeting => l10n.notificationPauseReasonMeeting,
  NotificationPauseReason.overnight => l10n.notificationPauseReasonOvernight,
};

/// Подпись срока паузы на устройстве пользователя: «сегодня, 18:00»,
/// «завтра, 08:00», «28.11, 09:00».
String formatNotificationPauseUntil(
  AppLocalizations l10n,
  DateTime until, {
  DateTime? now,
}) => formatChatSnoozeUntil(l10n, until, now: now);

/// Пункты меню паузы. Когда пауза не действует, пункта «включить» нет.
// ignore: avoid_classes_with_only_static_members, только пространство имён
abstract final class NotificationPauseMenu {
  static List<PopupMenuEntry<NotificationPauseChoice>> items(
    AppLocalizations l10n, {
    required bool active,
  }) => [
    for (final choice in NotificationPauseChoice.values)
      if (choice != NotificationPauseChoice.resume || active)
        PopupMenuItem(
          value: choice,
          child: Row(
            children: [
              Icon(
                choice == NotificationPauseChoice.resume
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
                size: 18,
              ),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  notificationPauseChoiceLabel(l10n, choice),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
  ];
}

/// Кнопка быстрой паузы уведомлений для шапки входящих.
///
/// Пока пауза действует, иконка перечёркнута, а подсказка показывает срок:
/// состояние общее для всех устройств, поэтому его видно и на телефоне, где
/// паузу поставили с компьютера.
class NotificationPauseButton extends StatelessWidget {
  const NotificationPauseButton({
    required this.activeUntil,
    required this.onSelected,
    super.key,
  });

  /// Срок действующей паузы. Null — уведомления включены.
  final DateTime? activeUntil;

  /// Вызывается только после выбора действия.
  final ValueChanged<NotificationPauseChoice> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final until = activeUntil;
    final tooltip = until == null
        ? l10n.settingsPauseTitle
        : l10n.notificationPauseTooltip(
            formatNotificationPauseUntil(l10n, until),
          );
    return PopupMenuButton<NotificationPauseChoice>(
      tooltip: tooltip,
      icon: Icon(
        until == null
            ? Icons.notifications_outlined
            : Icons.notifications_off_outlined,
      ),
      onSelected: onSelected,
      itemBuilder: (context) =>
          NotificationPauseMenu.items(l10n, active: until != null),
    );
  }
}
