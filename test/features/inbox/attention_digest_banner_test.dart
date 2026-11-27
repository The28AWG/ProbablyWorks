import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/inbox/presentation/widgets/attention_digest_banner.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';

void main() {
  testWidgets('shows a compact digest with a summary and actions', (
    tester,
  ) async {
    var dismissed = 0;
    var reviewed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AttentionDigestBanner(
            digest: const AttentionDigest(
              items: [
                AttentionDigestItem(
                  chatId: 'c1',
                  hostId: 'local',
                  title: 'Fix the build',
                  unreadMessages: 4,
                  finishedTurns: 2,
                  approvals: 1,
                  problems: 1,
                ),
              ],
            ),
            onDismiss: () => dismissed++,
            onReview: () => reviewed++,
          ),
        ),
      ),
    );

    expect(find.text('While you were away'), findsOneWidget);
    expect(
      find.text('1 decision · 1 problem · 4 new messages'),
      findsOneWidget,
    );

    await tester.tap(find.text('Review'));
    await tester.pump();
    expect(reviewed, 1);
    expect(dismissed, 0);

    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(dismissed, 1);
  });

  testWidgets('omits zero counters and uses the Russian wording', (
    tester,
  ) async {
    var dismissed = 0;
    var reviewed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('ru'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AttentionDigestBanner(
            digest: const AttentionDigest(
              items: [
                AttentionDigestItem(
                  chatId: 'c1',
                  hostId: 'local',
                  title: 'Чат',
                  approvals: 1,
                ),
              ],
            ),
            onDismiss: () => dismissed++,
            onReview: () => reviewed++,
          ),
        ),
      ),
    );

    expect(find.text('Пока вас не было'), findsOneWidget);
    expect(find.text('1 решение'), findsOneWidget);
    expect(find.textContaining('сообщени'), findsNothing);
  });

  testWidgets('stays compact with a long digest on a narrow screen', (
    tester,
  ) async {
    var dismissed = 0;
    var reviewed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 300)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 260,
                height: 80,
                child: AttentionDigestBanner(
                  digest: AttentionDigest(
                    items: [
                      for (var index = 0; index < 40; index++)
                        AttentionDigestItem(
                          chatId: 'c$index',
                          hostId: 'local',
                          title: 'Chat $index',
                          unreadMessages: 12,
                          finishedTurns: 7,
                          approvals: 2,
                          questions: 1,
                          editFileChanges: 1,
                          problems: 1,
                        ),
                    ],
                  ),
                  onDismiss: () => dismissed++,
                  onReview: () => reviewed++,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('While you were away'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsNothing);
    // На узком экране остаётся только иконка «Разобрать», крестика нет.
    expect(find.text('Review'), findsNothing);
    expect(find.byTooltip('Review'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
    expect(find.byTooltip('Close'), findsNothing);

    await tester.tap(find.byTooltip('Review'));
    await tester.pump();
    expect(reviewed, 1);

    await tester.drag(find.byType(Dismissible), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(dismissed, 1);
  });
}
