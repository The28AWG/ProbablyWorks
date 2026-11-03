import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/core/data/saved_model_repository.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/features/models/presentation/widgets/model_picker_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

class _FakeLlm implements LlmProvider {
  _FakeLlm(this.models);

  final List<LlmModelInfo> models;

  @override
  Future<void> checkKey() => Future<void>.value();

  @override
  Future<List<LlmModelInfo>> listModels() async => models;

  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      throw UnimplementedError('not used by the picker');
}

/// Каталог с загруженным списком [listed] и сохранёнными выбранными моделями [saved].
Future<ModelCatalogService> _catalog({
  required List<LlmModelInfo> listed,
  List<SavedModel> saved = const [],
}) async {
  final db = openInMemoryDatabase();
  addTearDown(db.close);
  final repository = SavedModelRepository(db);
  await repository.save(saved);
  final catalog = ModelCatalogService(repository, _FakeLlm(listed));
  await catalog.loadSaved();
  await catalog.refresh();
  return catalog;
}

/// Кнопка открывает диалог; результат (или null при закрытии) уходит в [onPicked].
class _Host extends StatelessWidget {
  _Host({
    required this.catalog,
    required this.currentId,
    required this.onPicked,
  });

  final ModelCatalogService catalog;
  final String? currentId;
  final void Function(LlmModelInfo?) onPicked;

  // Закрепление в этих тестах не проверяется; ids просто собираются.
  final _pins = <String>[];

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => _open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  Future<void> _open(BuildContext context) async {
    onPicked(
      await showModelPickerDialog(
        context,
        catalog: catalog,
        pinned: const [],
        currentId: currentId,
        onTogglePin: _pins.add,
      ),
    );
  }
}

void main() {
  const gpt = LlmModelInfo(
    id: 'openai/gpt-4o',
    name: 'GPT-4o',
    supportsTools: true,
  );

  testWidgets(
    'a departed current model is shown with a marker and cannot be picked',
    (tester) async {
      final catalog = await _catalog(
        listed: const [gpt],
        saved: const [
          SavedModel(
            id: 'anthropic/claude',
            name: 'Claude',
            supportsTools: true,
          ),
        ],
      );
      LlmModelInfo? picked;
      var closed = false;
      await tester.pumpWidget(
        _Host(
          catalog: catalog,
          currentId: 'anthropic/claude',
          onPicked: (value) {
            picked = value;
            closed = true;
          },
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

      expect(find.text(l10n.modelCurrentUnavailable), findsOneWidget);
      expect(find.text('! Claude'), findsOneWidget);

      // Нажатие на недоступную модель не закрывает диалог и ничего не выбирает.
      await tester.tap(find.text('! Claude'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(closed, isFalse);

      await tester.tap(find.text('GPT-4o'));
      await tester.pumpAndSettle();
      expect(picked?.id, 'openai/gpt-4o');
    },
  );

  testWidgets('closing the picker keeps the old choice', (tester) async {
    final catalog = await _catalog(listed: const [gpt]);
    LlmModelInfo? picked = gpt;
    await tester.pumpWidget(
      _Host(
        catalog: catalog,
        currentId: 'openai/gpt-4o',
        onPicked: (value) => picked = value,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    await tester.tap(find.text(l10n.commonClose));
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });
}
