import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/settings/presentation/widgets/data_settings_section.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/data_api.dart';

const _usage = DataUsage(
  chats: 2,
  subagentChats: 0,
  messages: 10,
  toolRuns: 3,
  scheduledTasks: 1,
  completedTasks: 2,
  failedTasks: 0,
  cancelledTasks: 0,
  chatFilesBytes: 1024,
  databaseBytes: 2048,
);

final class _FakeDataApi implements DataApi {
  _FakeDataApi({this.failUsage = false, this.compacted = true});

  final bool failUsage;
  final bool compacted;
  int? clearedDays;

  @override
  Future<DataUsage> usage() async {
    if (failUsage) throw StateError('offline');
    return _usage;
  }

  @override
  Future<HistoryClearResult> clearHistory({int? olderThanDays}) async {
    clearedDays = olderThanDays;
    return HistoryClearResult(
      deletedChats: 2,
      freedBytes: 512,
      compacted: compacted,
    );
  }

  @override
  Future<void> resetSettings() => Future<void>.value();
}

class _Host extends StatelessWidget {
  const _Host({
    required this.api,
    required this.onReset,
    this.locale = const Locale('en'),
    this.offline = false,
  });

  final DataApi api;
  final VoidCallback onReset;
  final Locale locale;
  final bool offline;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: locale,
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: DataSettingsSection(
          api: api,
          onReset: onReset,
          offline: offline,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('shows usage and clears the chosen age', (tester) async {
    final api = _FakeDataApi();
    var resets = 0;
    await tester.pumpWidget(_Host(api: api, onReset: () => resets++));
    await tester.pumpAndSettle();

    expect(find.text('2 chats'), findsOneWidget);
    expect(find.text('10 messages'), findsOneWidget);
    expect(find.text('1 scheduled task'), findsOneWidget);
    expect(find.text('2 completed tasks'), findsOneWidget);
    expect(find.textContaining('failed task'), findsNothing);
    // Действие стоит под описанием, а не в одной строке с заголовком:
    // иначе высокая кнопка прижимается к тексту и элементы слипаются.
    expect(
      tester.getTopLeft(find.byIcon(Icons.delete_outline).last).dy,
      greaterThan(
        tester.getBottomLeft(find.textContaining('Deletes chats')).dy,
      ),
    );

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Not updated for 30 days'), findsOneWidget);

    await tester.tap(find.text('Not updated for 30 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(api.clearedDays, 30);
    expect(resets, 0);
    expect(find.text('Deleted chats: 2. Freed: 512 B.'), findsOneWidget);
  });

  testWidgets('fits a narrow screen and its dialog', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var resets = 0;
    await tester.pumpWidget(
      _Host(api: _FakeDataApi(), onReset: () => resets++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(resets, 0);
  });
  testWidgets('fits Russian labels on a narrow screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var resets = 0;
    await tester.pumpWidget(
      _Host(
        api: _FakeDataApi(),
        onReset: () => resets++,
        locale: const Locale('ru'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byIcon(Icons.restart_alt).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.restart_alt).last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(resets, 0);
  });
  testWidgets('destructive actions are red on the page and in the dialog', (
    tester,
  ) async {
    var resets = 0;
    await tester.pumpWidget(
      _Host(api: _FakeDataApi(), onReset: () => resets++),
    );
    await tester.pumpAndSettle();

    final clear = tester.widget<OutlinedButton>(
      find
          .ancestor(
            of: find.byIcon(Icons.delete_outline),
            matching: find.byWidgetPredicate(
              (widget) => widget is OutlinedButton,
            ),
          )
          .first,
    );
    final reset = tester.widget<OutlinedButton>(
      find
          .ancestor(
            of: find.byIcon(Icons.restart_alt),
            matching: find.byWidgetPredicate(
              (widget) => widget is OutlinedButton,
            ),
          )
          .first,
    );
    for (final button in [clear, reset]) {
      expect(
        button.style?.foregroundColor?.resolve(const <WidgetState>{}),
        AppTheme.light.colorScheme.error,
      );
    }

    await tester.ensureVisible(find.byIcon(Icons.restart_alt).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.restart_alt).last);
    await tester.pumpAndSettle();

    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Reset'),
    );
    expect(
      confirm.style?.backgroundColor?.resolve(const <WidgetState>{}),
      AppTheme.light.colorScheme.error,
    );
    await tester.tap(find.text('Cancel'));
    expect(resets, 0);
  });
  testWidgets('keeps a consistent vertical rhythm', (tester) async {
    var resets = 0;
    await tester.pumpWidget(
      _Host(api: _FakeDataApi(), onReset: () => resets++),
    );
    await tester.pumpAndSettle();

    double gapBetween(Finder top, Finder bottom) =>
        tester.getTopLeft(top).dy - tester.getBottomLeft(bottom).dy;

    // Заголовок и его пояснение стоят рядом; большое расстояние появлялось,
    // когда кнопка обновления раздувала строку заголовка.
    expect(
      gapBetween(
        find.text('Chats, logs and the database of this profile.'),
        find.text('Disk usage'),
      ),
      lessThanOrEqualTo(AppSpacing.sm),
    );
    expect(
      gapBetween(
        find.textContaining('Deletes chats'),
        find.text('Chat history'),
      ),
      lessThanOrEqualTo(AppSpacing.sm),
    );
    expect(
      gapBetween(
        find.textContaining('Returns models'),
        find.text('Preferences'),
      ),
      lessThanOrEqualTo(AppSpacing.sm),
    );

    // Между подпунктами раздела отступ того же порядка, что внутри AppSection.
    final clearButton = find
        .ancestor(
          of: find.byIcon(Icons.delete_outline),
          matching: find.byWidgetPredicate(
            (widget) => widget is OutlinedButton,
          ),
        )
        .first;
    expect(
      gapBetween(find.text('Preferences'), clearButton),
      greaterThanOrEqualTo(AppSpacing.md),
    );
    expect(resets, 0);
  });
  testWidgets('usage placeholder does not overlap the refresh icon', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var resets = 0;
    await tester.pumpWidget(
      _Host(
        api: _FakeDataApi(failUsage: true),
        onReset: () => resets++,
        locale: const Locale('ru'),
      ),
    );
    await tester.pumpAndSettle();

    final icon = tester.getRect(find.byIcon(Icons.refresh));
    final placeholder = tester.getRect(
      find.descendant(
        of: find.byType(AppCard),
        matching: find.text('Чаты, логи и база этого профиля.'),
      ),
    );
    expect(icon.overlaps(placeholder), isFalse);
    expect(resets, 0);
  });

  testWidgets('warns when the database was not compacted', (tester) async {
    var resets = 0;
    await tester.pumpWidget(
      _Host(api: _FakeDataApi(compacted: false), onReset: () => resets++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be compacted'), findsOneWidget);
  });
  testWidgets('offline shows only the interface reset', (tester) async {
    var resets = 0;
    await tester.pumpWidget(
      _Host(
        api: _FakeDataApi(failUsage: true),
        onReset: () => resets++,
        offline: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Agent is offline'), findsOneWidget);
    expect(find.text('Disk usage'), findsNothing);
    expect(find.text('Chat history'), findsNothing);
    expect(find.text('Reset settings'), findsOneWidget);
    expect(resets, 0);
  });
  testWidgets('loads usage when the agent comes back online', (tester) async {
    final api = _FakeDataApi();
    var resets = 0;
    await tester.pumpWidget(
      _Host(api: api, onReset: () => resets++, offline: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('Disk usage'), findsNothing);

    await tester.pumpWidget(
      _Host(api: api, onReset: () => resets++, offline: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('Disk usage'), findsOneWidget);
    expect(find.text('2 chats'), findsOneWidget);
    expect(resets, 0);
  });
}
