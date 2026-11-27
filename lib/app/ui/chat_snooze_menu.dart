import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Сроки «напомнить позже», которые предлагает интерфейс.
///
/// Набор намеренно короткий. Произвольная дата давала бы диалог с календарём
/// ради редкого случая, а «когда буду за компьютером» требует признака
/// активного устройства, которого в модели пока нет.
enum ChatSnoozePreset {
  /// Через час от текущего момента.
  hour,

  /// Сегодня в 18:00; если это время уже прошло — завтра в 18:00.
  evening,

  /// Завтра в 09:00.
  tomorrow,

  /// Ближайший будний день в 09:00.
  nextWorkday;

  /// Момент срока для [now] в локальной зоне.
  ///
  /// Считает клиент, а не сервер: «завтра утром» — это утро там, где сидит
  /// пользователь, а на сервере может быть другой часовой пояс.
  DateTime deadline(DateTime now) => switch (this) {
    ChatSnoozePreset.hour => now.add(const Duration(hours: 1)),
    ChatSnoozePreset.evening => _nextEvening(now),
    ChatSnoozePreset.tomorrow => _at(_nextDay(now), 9),
    ChatSnoozePreset.nextWorkday => _nextWorkday(now, 9),
  };
}

/// Название срока в меню.
String chatSnoozePresetLabel(AppLocalizations l10n, ChatSnoozePreset preset) =>
    switch (preset) {
      ChatSnoozePreset.hour => l10n.chatSnoozePresetHour,
      ChatSnoozePreset.evening => l10n.chatSnoozePresetEvening,
      ChatSnoozePreset.tomorrow => l10n.chatSnoozePresetTomorrow,
      ChatSnoozePreset.nextWorkday => l10n.chatSnoozePresetNextWorkday,
    };

/// Подпись срока в карточках и подсказках: «сегодня, 18:00», «завтра, 09:00»,
/// «28.11, 09:00».
///
/// Сравнение идёт по календарным датам в локальной зоне, а не по разнице
/// часов: переход на летнее время не должен превращать «завтра» в «сегодня».
String formatChatSnoozeUntil(
  AppLocalizations l10n,
  DateTime until, {
  DateTime? now,
}) {
  final local = until.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}';
  final days = DateTime.utc(
    local.year,
    local.month,
    local.day,
  ).difference(DateTime.utc(current.year, current.month, current.day)).inDays;
  return switch (days) {
    0 => l10n.chatSnoozeToday(time),
    1 => l10n.chatSnoozeTomorrow(time),
    _ => l10n.chatSnoozeMoment('${two(local.day)}.${two(local.month)}', time),
  };
}

/// Пункты меню сроков. Общий список, чтобы меню чата и карточки входящих
/// предлагали одно и то же.
// ignore: avoid_classes_with_only_static_members, только пространство имён
abstract final class ChatSnoozeMenu {
  static List<PopupMenuEntry<ChatSnoozePreset>> items(AppLocalizations l10n) =>
      [
        for (final preset in ChatSnoozePreset.values)
          PopupMenuItem(
            value: preset,
            child: Row(
              children: [
                const Icon(Icons.snooze_outlined, size: 18),
                const SizedBox(width: AppSpacing.sm),
                Flexible(
                  child: Text(
                    chatSnoozePresetLabel(l10n, preset),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ];
}

/// Открывает меню сроков рядом с [position] и возвращает выбранный момент.
///
/// Null — пользователь закрыл меню, ничего не выбрав.
Future<DateTime?> showChatSnoozeMenu(
  BuildContext context,
  RelativeRect position, {
  DateTime? now,
}) async {
  final l10n = AppLocalizations.of(context);
  final preset = await showMenu<ChatSnoozePreset>(
    context: context,
    position: position,
    items: ChatSnoozeMenu.items(l10n),
  );
  if (preset == null) return null;
  return preset.deadline(now ?? DateTime.now());
}

/// Кнопка «Напомнить позже» с меню сроков.
///
/// Кнопка, а не пункт меню: отложить чат можно прямо в карточке входящих, не
/// открывая чат и не принимая решение немедленно.
class ChatSnoozeButton extends StatelessWidget {
  const ChatSnoozeButton({required this.onSelected, super.key});

  /// Вызывается только после выбора срока: закрытие меню ничего не меняет.
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Builder(
      builder: (context) => TextButton.icon(
        onPressed: () => _open(context),
        icon: const Icon(Icons.snooze_outlined, size: 18),
        label: Text(l10n.inboxSnooze),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final overlayBox = Overlay.of(context).context.findRenderObject();
    if (overlayBox is! RenderBox) return;
    final until = await showChatSnoozeMenu(
      context,
      RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlayBox),
          box.localToGlobal(
            box.size.bottomRight(Offset.zero),
            ancestor: overlayBox,
          ),
        ),
        Offset.zero & overlayBox.size,
      ),
    );
    if (until != null) onSelected(until);
  }
}

/// Пункт контекстного меню чата, открывающий меню сроков.
///
/// Отдельная позиция меню, а не подменю: Material не поддерживает вложенные
/// меню, а второй шаг показывает те же сроки, что и кнопка во входящих.
Future<DateTime?> showChatSnoozeMenuAt(BuildContext context, Offset position) =>
    showChatSnoozeMenu(
      context,
      RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
    );

DateTime _at(DateTime day, int hour) =>
    DateTime(day.year, day.month, day.day, hour);

/// Следующий календарный день.
///
/// Не `now.add(Duration(days: 1))`: при переходе на летнее время сутки могут
/// оказаться длиннее или короче 24 часов, и дата сдвинулась бы не туда.
DateTime _nextDay(DateTime day) => DateTime(day.year, day.month, day.day + 1);

DateTime _nextEvening(DateTime now) {
  final today = _at(now, 18);
  if (today.isAfter(now)) return today;
  return _at(_nextDay(now), 18);
}

/// Ближайший будний день в [hour], строго после [now].
DateTime _nextWorkday(DateTime now, int hour) {
  var candidate = _at(now, hour);
  // Неделя — предел: два выходных подряд, дальше день точно рабочий.
  for (var step = 0; step < 8; step++) {
    final weekday = candidate.weekday;
    if (candidate.isAfter(now) &&
        weekday != DateTime.saturday &&
        weekday != DateTime.sunday) {
      return candidate;
    }
    candidate = _at(_nextDay(candidate), hour);
  }
  return candidate;
}
