import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/chat_snooze_menu.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

void main() {
  // Пятница, вечер: все сроки уже не «сегодня утром», поэтому проверки не
  // зависят от часа запуска теста.
  final now = DateTime(2026, 11, 27, 19, 30);

  test('presets resolve in the local calendar', () {
    expect(ChatSnoozePreset.hour.deadline(now), DateTime(2026, 11, 27, 20, 30));
    // Вечер уже прошёл — напоминание переносится на завтрашний вечер.
    expect(ChatSnoozePreset.evening.deadline(now), DateTime(2026, 11, 28, 18));
    expect(ChatSnoozePreset.tomorrow.deadline(now), DateTime(2026, 11, 28, 9));
    // Суббота и воскресенье пропускаются.
    expect(
      ChatSnoozePreset.nextWorkday.deadline(now),
      DateTime(2026, 11, 30, 9),
    );
  });

  test('the evening preset stays today before 18:00', () {
    final morning = DateTime(2026, 11, 27, 9);
    expect(
      ChatSnoozePreset.evening.deadline(morning),
      DateTime(2026, 11, 27, 18),
    );
    // Рабочий день ещё не начался — срок сегодня.
    expect(
      ChatSnoozePreset.nextWorkday.deadline(DateTime(2026, 11, 27, 8)),
      DateTime(2026, 11, 27, 9),
    );
  });

  testWidgets('the deadline label names today, tomorrow and a date', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      formatChatSnoozeUntil(l10n, DateTime(2026, 11, 27, 18), now: now),
      'today, 18:00',
    );
    expect(
      formatChatSnoozeUntil(l10n, DateTime(2026, 11, 28, 9), now: now),
      'tomorrow, 09:00',
    );
    expect(
      formatChatSnoozeUntil(l10n, DateTime(2026, 11, 30, 9), now: now),
      '30.11, 09:00',
    );
    // Срок на завтра не становится «сегодня» только из-за того, что он ближе
    // 17 часов: сравнение идёт по календарным датам.
    expect(
      formatChatSnoozeUntil(l10n, DateTime(2026, 11, 28, 1), now: now),
      'tomorrow, 01:00',
    );
  });
}
