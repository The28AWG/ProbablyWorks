import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_context_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

import 'package:probably_works/test_support/golden_fonts.dart';

Future<void> _open(
  WidgetTester tester, {
  int? used,
  bool running = false,
  required VoidCallback onCompact,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ChatContextDialog(
                  used: used,
                  limit: 128000,
                  running: running,
                  onCompact: onCompact,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(GoldenFonts.load);

  testWidgets('shows usage and runs compaction, then closes', (tester) async {
    var compacted = 0;
    await _open(tester, used: 96000, onCompact: () => compacted++);
    expect(find.text('Context 96 000 / 128 000 tokens'), findsOneWidget);
    await tester.tap(find.text('Compact'));
    await tester.pumpAndSettle();
    expect(compacted, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('no data yet: compaction is unavailable', (tester) async {
    var compacted = 0;
    await _open(tester, onCompact: () => compacted++);
    expect(
      find.text("No data yet. It appears after the model's first reply."),
      findsOneWidget,
    );
    await tester.tap(find.text('Compact'));
    await tester.pumpAndSettle();
    expect(compacted, 0);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('running agent: compaction is unavailable', (tester) async {
    var compacted = 0;
    await _open(
      tester,
      used: 50000,
      running: true,
      onCompact: () => compacted++,
    );
    await tester.tap(find.text('Compact'));
    await tester.pumpAndSettle();
    expect(compacted, 0);
  });

  testWidgets('close button dismisses the dialog', (tester) async {
    await _open(tester, used: 1000, onCompact: () {
      return;
    });
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
