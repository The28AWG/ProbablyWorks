import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/settings/presentation/widgets/notification_pause_section.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/api/attention_pause_api.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/notification_pause.dart';

final class _FakeAttention implements AttentionApi, AttentionPauseApi {
  AttentionSnapshot value = AttentionSnapshot.empty;
  final changes = StreamController<AttentionSnapshot>.broadcast();
  final paused = <(DateTime, NotificationPauseReason)>[];
  DateTime? resumedUntil;

  @override
  Future<AttentionSnapshot> attention() async => value;

  @override
  Stream<AttentionSnapshot> get attentionChanges => changes.stream;

  @override
  Future<void> dismissAttention(String chatId) => Future<void>.value();

  @override
  bool get supportsPause => true;

  @override
  Future<void> pauseNotifications(
    DateTime until, {
    NotificationPauseReason reason = NotificationPauseReason.focus,
  }) async {
    paused.add((until, reason));
    value = AttentionSnapshot(
      revision: value.revision + 1,
      items: const [],
      pause: NotificationPause(until: until, reason: reason, revision: 1),
    );
    changes.add(value);
  }

  @override
  Future<void> resumeNotifications() async {
    resumedUntil = value.pause?.until;
    value = AttentionSnapshot(revision: value.revision + 1, items: const []);
    changes.add(value);
  }

  @override
  Stream<AttentionDigest> get pauseDigestDue =>
      const Stream<AttentionDigest>.empty();
}

void main() {
  testWidgets('starts a focus pause and resumes it', (tester) async {
    final api = _FakeAttention();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NotificationPauseSection(attentionApi: api, pauseApi: api),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Focus for 30 minutes'));
    await tester.pumpAndSettle();

    expect(api.paused, hasLength(1));
    expect(api.paused.single.$2, NotificationPauseReason.focus);
    expect(
      api.paused.single.$1.difference(DateTime.now()).inMinutes,
      inInclusiveRange(28, 30),
    );
    expect(find.text('Resume notifications'), findsOneWidget);

    await tester.tap(find.text('Resume notifications'));
    await tester.pumpAndSettle();

    expect(api.resumedUntil, isNotNull);
    expect(find.text('Focus for 30 minutes'), findsOneWidget);
  });

  testWidgets('a stale snapshot does not reset the shown pause', (
    tester,
  ) async {
    final api = _FakeAttention();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NotificationPauseSection(attentionApi: api, pauseApi: api),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Focus for 30 minutes'));
    await tester.pumpAndSettle();
    expect(find.text('Resume notifications'), findsOneWidget);

    // Запоздавший снимок до паузы не должен вернуть кнопки пресетов.
    api.changes.add(const AttentionSnapshot(revision: 0, items: []));
    await tester.pumpAndSettle();

    expect(find.textContaining('Focus ·'), findsOneWidget);
    expect(find.text('Focus for 30 minutes'), findsNothing);
  });
}
