import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

class _TestHost extends StatelessWidget {
  const _TestHost(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('AppBanner shows message and action', (tester) async {
    await tester.pumpWidget(
      _TestHost(
        AppBanner(
          title: 'Title',
          message: 'Body text',
          tone: AppTone.warning,
          action: TextButton(
            onPressed: () {
              return;
            },
            child: const Text('Act'),
          ),
        ),
      ),
    );
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Body text'), findsOneWidget);
    expect(find.text('Act'), findsOneWidget);
  });

  testWidgets('StatusChip renders label in every tone', (tester) async {
    for (final tone in AppTone.values) {
      await tester.pumpWidget(
        _TestHost(StatusChip(label: tone.name, tone: tone, pulse: true)),
      );
      expect(find.text(tone.name), findsOneWidget);
    }
  });

  testWidgets('ConfirmDialog.confirm resolves true on confirm', (tester) async {
    bool? result;
    await tester.pumpWidget(
      _TestHost(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await ConfirmDialog.confirm(
                context,
                title: 'Delete?',
                message: 'Sure?',
                cancelLabel: 'No',
                confirmLabel: 'Yes',
                destructive: true,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Delete?'), findsOneWidget);
    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('ConfirmDialog.confirm resolves false on cancel', (tester) async {
    bool? result;
    await tester.pumpWidget(
      _TestHost(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await ConfirmDialog.confirm(
                context,
                title: 'Delete?',
                cancelLabel: 'No',
                confirmLabel: 'Yes',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('ConfirmDialog.prompt returns edited text', (tester) async {
    String? result;
    await tester.pumpWidget(
      _TestHost(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await ConfirmDialog.prompt(
                context,
                title: 'Rename',
                cancelLabel: 'Cancel',
                confirmLabel: 'Save',
                initialText: 'old',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'new name');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, 'new name');
  });

  testWidgets('DiffView renders added and removed lines', (tester) async {
    await tester.pumpWidget(
      _TestHost(const DiffView(diff: '- old line\n+ new line\n… diff truncated')),
    );
    expect(find.textContaining('old line'), findsOneWidget);
    expect(find.textContaining('new line'), findsOneWidget);
    expect(find.textContaining('diff truncated'), findsOneWidget);
  });

  testWidgets('CodeBlock copy button is labelled', (tester) async {
    await tester.pumpWidget(_TestHost(const CodeBlock(text: 'ls -la')));
    expect(find.byTooltip('Copy'), findsOneWidget);
    expect(find.text('ls -la'), findsOneWidget);
  });

  testWidgets('ActionCard shows title, body and actions', (tester) async {
    await tester.pumpWidget(
      _TestHost(
        ActionCard(
          title: 'Approve?',
          actions: [
            FilledButton(
              onPressed: () {
                return;
              },
              child: const Text('Go'),
            ),
          ],
          children: const [Text('body')],
        ),
      ),
    );
    expect(find.text('Approve?'), findsOneWidget);
    expect(find.text('body'), findsOneWidget);
    expect(find.text('Go'), findsOneWidget);
  });

  testWidgets('AppEmptyState shows title and message', (tester) async {
    await tester.pumpWidget(
      _TestHost(
        const AppEmptyState(
          icon: Icons.inbox_outlined,
          title: 'Nothing here',
          message: 'Create something',
        ),
      ),
    );
    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('Create something'), findsOneWidget);
  });

  testWidgets('OnboardingStepper shows counter label', (tester) async {
    await tester.pumpWidget(
      _TestHost(
        const OnboardingStepper(
          index: 1,
          total: 6,
          counterLabel: 'Step 2 of 6',
        ),
      ),
    );
    expect(find.text('Step 2 of 6'), findsOneWidget);
  });

  testWidgets('ContextUsageBar clamps fraction above one', (tester) async {
    await tester.pumpWidget(
      _TestHost(const ContextUsageBar(label: 'Context', fraction: 3)),
    );
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, 1.0);
  });
}
