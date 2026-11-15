import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/models/domain/model_selection.dart';
import 'package:probably_works/features/settings/presentation/widgets/model_setting_field.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

class _Catalog implements ModelCatalogSource {
  _Catalog(this.state);

  @override
  final ModelCatalogState state;

  @override
  Stream<ModelCatalogState> watch() => Stream.value(state);

  @override
  Future<void> refresh() => Future<void>.value();
}

void main() {
  testWidgets('the reasoning dropdown has no label and cannot be typed into', (
    tester,
  ) async {
    final catalog = _Catalog(
      ModelCatalogState(
        models: const [
          LlmModelInfo(
            id: 'openai/gpt-4o',
            name: 'GPT-4o',
            reasoning: LlmReasoningCapability(
              supported: true,
              efforts: [ReasoningEffort.low, ReasoningEffort.high],
            ),
          ),
        ],
        syncedAt: DateTime(2026),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ModelSettingField(
            modelId: 'openai/gpt-4o',
            reasoning: ReasoningPreference.auto,
            catalog: catalog.state,
            source: catalog,
            pinned: const [],
            onSelected: _noopSelection,
            onReasoningSelected: _noopReasoning,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final dropdown = tester.widget<DropdownMenu<ReasoningPreference>>(
      find.byType(DropdownMenu<ReasoningPreference>),
    );
    expect(dropdown.label, isNull);
    expect(dropdown.hintText, isNull);
    expect(dropdown.requestFocusOnTap, isFalse);
    expect(dropdown.enableFilter, isFalse);

    await tester.tap(find.byType(DropdownMenu<ReasoningPreference>));
    await tester.pumpAndSettle();
    expect(find.text('High'), findsWidgets);
    expect(tester.testTextInput.isVisible, isFalse);
  });
}

void _noopSelection(ModelSelection _) {
  return;
}

void _noopReasoning(ReasoningPreference _) {
  return;
}
