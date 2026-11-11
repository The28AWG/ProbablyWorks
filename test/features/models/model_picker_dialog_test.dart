import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/models/presentation/widgets/model_picker_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/data/saved_model_repository.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

class _FakeLlm implements LlmProvider {
  _FakeLlm(this.models);

  final List<LlmModelInfo> models;

  @override
  Future<LlmKeyInfo> checkKey() =>
      Future.value(const LlmKeyInfo(label: 'test', usage: 0));

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
    this.pinnable = true,
    this.requireTools = true,
    this.managePins = false,
    List<String>? pins,
  }) : pins = pins ?? [];

  final ModelCatalogService catalog;
  final String? currentId;
  final void Function(LlmModelInfo?) onPicked;

  /// Есть ли у строк кнопка закрепления (композер — да, настройки модели — нет).
  final bool pinnable;
  final bool requireTools;

  /// Закреплённые id: нажатие переключает модель (как в приложении), список видно из теста.
  final List<String> pins;

  final bool managePins;

  void _toggle(String id) {
    if (!pins.remove(id)) pins.add(id);
  }

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
        onTogglePin: pinnable ? _toggle : null,
        requireTools: requireTools,
        managePins: managePins,
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

  const plain = LlmModelInfo(id: 'x/plain', name: 'Plain');

  testWidgets('without onTogglePin rows have no pin button', (tester) async {
    final catalog = await _catalog(listed: const [gpt]);
    await tester.pumpWidget(
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: _ignorePick,
        pinnable: false,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.star_border), findsNothing);
    expect(find.byIcon(Icons.star), findsNothing);
  });

  testWidgets('with onTogglePin rows show the pin button', (tester) async {
    final catalog = await _catalog(listed: const [gpt]);
    await tester.pumpWidget(
      _Host(catalog: catalog, currentId: null, onPicked: _ignorePick),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.star_border), findsOneWidget);
  });

  testWidgets('manage mode: a tap pins and unpins without closing', (
    tester,
  ) async {
    final catalog = await _catalog(listed: const [gpt]);
    final pins = <String>[];
    LlmModelInfo? picked;
    var closed = false;
    await tester.pumpWidget(
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: (value) {
          picked = value;
          closed = true;
        },
        managePins: true,
        requireTools: false,
        pins: pins,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('GPT-4o'));
    await tester.pumpAndSettle();
    expect(pins, ['openai/gpt-4o']);
    expect(find.byType(Dialog), findsOneWidget);
    expect(closed, isFalse);

    await tester.tap(find.text('GPT-4o'));
    await tester.pumpAndSettle();
    expect(pins, isEmpty);
    expect(picked, isNull);
  });

  testWidgets('manage mode lets a model without tools be pinned', (
    tester,
  ) async {
    // Одна строка: вторая уходит за край окна теста и не получает нажатие.
    final catalog = await _catalog(listed: const [plain]);
    final pins = <String>[];
    await tester.pumpWidget(
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: _ignorePick,
        managePins: true,
        requireTools: false,
        pins: pins,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Plain'));
    await tester.pumpAndSettle();
    expect(pins, ['x/plain']);
  });

  testWidgets('requireTools false lets a model without tools be picked', (
    tester,
  ) async {
    final catalog = await _catalog(listed: const [gpt, plain]);
    LlmModelInfo? picked;
    await tester.pumpWidget(
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: (value) => picked = value,
        pinnable: false,
        requireTools: false,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    // Бейдж «нет tool calling» нужен только тем, кому инструменты требуются.
    expect(find.text(l10n.modelNoTools), findsNothing);
    await tester.tap(find.text('Plain'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'x/plain');
  });

  testWidgets('requireTools true keeps a model without tools unpicked', (
    tester,
  ) async {
    final catalog = await _catalog(listed: const [gpt, plain]);
    LlmModelInfo? picked;
    await tester.pumpWidget(
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: (value) => picked = value,
        pinnable: false,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    // По умолчанию фильтр «tool calling» скрывает модели без инструментов.
    expect(find.text('Plain'), findsNothing);

    // Фильтр снят вручную: модель видна с бейджем, но выбрать её нельзя.
    await tester.tap(find.text(l10n.modelFilterToolsOnly));
    await tester.pumpAndSettle();
    expect(find.text(l10n.modelNoTools), findsOneWidget);
    await tester.tap(find.text('Plain'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(picked, isNull);
  });

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

void _ignorePick(LlmModelInfo? _) {
  return;
}
