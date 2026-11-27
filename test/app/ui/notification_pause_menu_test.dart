import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/notification_pause_menu.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/notification_pause.dart';

void main() {
  final now = DateTime(2026, 11, 27, 19, 30);

  test('presets resolve to the expected local deadlines', () {
    expect(
      NotificationPauseChoice.focus.deadline(now),
      DateTime(2026, 11, 27, 20),
    );
    expect(
      NotificationPauseChoice.meeting.deadline(now),
      DateTime(2026, 11, 27, 20, 30),
    );
    // Вечером «до утра» — это завтрашние 08:00, а не сегодняшние.
    expect(
      NotificationPauseChoice.overnight.deadline(now),
      DateTime(2026, 11, 28, 8),
    );
    expect(NotificationPauseChoice.resume.deadline(now), isNull);
  });

  test('an early morning pause ends on the same morning', () {
    expect(
      NotificationPauseChoice.overnight.deadline(DateTime(2026, 11, 27, 6)),
      DateTime(2026, 11, 27, 8),
    );
  });

  test('each choice maps to a pause reason except resume', () {
    expect(NotificationPauseChoice.focus.reason, NotificationPauseReason.focus);
    expect(
      NotificationPauseChoice.meeting.reason,
      NotificationPauseReason.meeting,
    );
    expect(
      NotificationPauseChoice.overnight.reason,
      NotificationPauseReason.overnight,
    );
    expect(NotificationPauseChoice.resume.reason, isNull);
  });

  testWidgets('labels are localized and the deadline uses the snooze format', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(
      notificationPauseChoiceLabel(l10n, NotificationPauseChoice.focus),
      'Focus for 30 minutes',
    );
    expect(
      notificationPauseChoiceLabel(l10n, NotificationPauseChoice.resume),
      'Resume notifications',
    );
    expect(
      notificationPauseReasonLabel(l10n, NotificationPauseReason.meeting),
      'Meeting',
    );
    expect(
      formatNotificationPauseUntil(l10n, DateTime(2026, 11, 28, 8), now: now),
      'tomorrow, 08:00',
    );
  });
}
