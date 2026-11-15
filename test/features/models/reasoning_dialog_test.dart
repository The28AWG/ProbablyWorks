import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/models/presentation/widgets/reasoning_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

Future<ReasoningPreference?> _open(
  WidgetTester tester, {
  required LlmReasoningCapability capability,
  ReasoningPreference initial = ReasoningPreference.auto,
  bool allowInherit = false,
}) async {
  ReasoningPreference? result;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showReasoningDialog(
                  context,
                  modelName: 'Test model',
                  capability: capability,
                  initial: initial,
                  defaultPreference: ReasoningPreference.medium,
                  allowInherit: allowInherit,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('shows only supported levels and returns the selected one', (
    tester,
  ) async {
    await _open(
      tester,
      capability: const LlmReasoningCapability(
        supported: true,
        efforts: [ReasoningEffort.low, ReasoningEffort.medium],
      ),
      allowInherit: true,
    );

    expect(find.text('Reasoning for Test model'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Low'), findsOneWidget);
    expect(find.text('Medium'), findsOneWidget);
    expect(find.text('High'), findsNothing);

    await tester.tap(find.text('Medium'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Reasoning for Test model'), findsNothing);
  });

  testWidgets('mandatory models do not offer Off', (tester) async {
    await _open(
      tester,
      capability: const LlmReasoningCapability(
        supported: true,
        mandatory: true,
        efforts: [ReasoningEffort.medium],
      ),
    );

    expect(find.text('Off'), findsNothing);
    expect(find.text('Medium'), findsOneWidget);
  });

  testWidgets('a model without reasoning only offers Auto', (tester) async {
    await _open(
      tester,
      capability: const LlmReasoningCapability(supported: false),
      allowInherit: true,
    );

    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Off'), findsNothing);
    expect(find.text('High'), findsNothing);
  });
}
