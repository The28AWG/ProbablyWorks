import 'package:app_ui/app_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/models/domain/model_list_query.dart';
import 'package:probably_works/features/models/domain/model_picker_sort_store.dart';
import 'package:probably_works/features/models/presentation/widgets/model_picker_dialog.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/data/saved_model_repository.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

class _FakeLlm extends LlmProviderBase {
  _FakeLlm(this.models)
    : super(const LlmProviderDescriptor(id: 'test', label: 'Test'));

  final List<LlmModelInfo> models;

  @override
  Future<List<LlmModelInfo>> listModels() async => models;

  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      throw UnimplementedError('not used by the picker');
}

final class _FakeRuntime implements ModelRuntimeSource {
  _FakeRuntime(this.state);

  final ModelRuntimeState state;
  final loaded = <String>[];
  final unloaded = <String>[];

  @override
  ModelRuntimeState get runtime => state;

  @override
  Stream<ModelRuntimeState> watchRuntime() => Stream.value(state);

  @override
  Future<void> refreshRuntime() => Future<void>.value();

  @override
  Future<void> loadModel(String modelId) async => loaded.add(modelId);

  @override
  Future<void> unloadModel(String modelId) async => unloaded.add(modelId);
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
    this.runtime,
    this.pinnable = true,
    this.requireTools = true,
    this.managePins = false,
    this.sortStore,
    this.platform,
    List<String>? pins,
  }) : pins = pins ?? [];

  final ModelCatalogService catalog;
  final ModelRuntimeSource? runtime;
  final String? currentId;
  final void Function(LlmModelInfo?) onPicked;

  /// Есть ли у строк кнопка закрепления (композер — да, настройки модели — нет).
  final bool pinnable;
  final bool requireTools;

  /// Закреплённые id: нажатие переключает модель (как в приложении), список видно из теста.
  final List<String> pins;

  final bool managePins;

  /// Хранилище сортировки. Null — порядок живёт только в диалоге.
  final ModelPickerSortStore? sortStore;

  /// Платформа темы: на десктопе кнопка копирования появляется по наведению.
  final TargetPlatform? platform;

  void _toggle(String id) {
    if (!pins.remove(id)) pins.add(id);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: platform == null
        ? AppTheme.light
        : AppTheme.light.copyWith(platform: platform),
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
        runtime: runtime,
        pinned: const [],
        currentId: currentId,
        onTogglePin: pinnable ? _toggle : null,
        requireTools: requireTools,
        managePins: managePins,
        sortStore: sortStore,
      ),
    );
  }
}

/// Открывает диалог и дожидается его появления.
Future<void> _openPicker(WidgetTester tester, _Host host) async {
  await tester.pumpWidget(host);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

String _searchText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byType(AppTextField),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

/// Текст значения селекта сортировки: поле ввода меню не доступно снаружи.
String _sortValue(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byType(AppSelect<ModelSort>),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

void main() {
  const gpt = LlmModelInfo(
    id: 'openai/gpt-4o',
    name: 'GPT-4o',
    supportsTools: true,
  );
  const claude = LlmModelInfo(
    id: 'anthropic/claude',
    name: 'Claude',
    supportsTools: true,
  );
  const llama = LlmModelInfo(
    id: 'meta/llama',
    name: 'Llama',
    supportsTools: true,
  );
  const plain = LlmModelInfo(id: 'x/plain', name: 'Plain');
  const freeModel = LlmModelInfo(
    id: 'meta/free',
    name: 'Free',
    supportsTools: true,
    promptPrice: '0',
    completionPrice: '0',
  );

  testWidgets('a narrow window hides the id and filter hint', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(300, 680);
    addTearDown(tester.view.reset);
    final catalog = await _catalog(listed: const [gpt]);
    await _openPicker(
      tester,
      _Host(catalog: catalog, currentId: null, onPicked: _ignorePick),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    // id не показывается в строке: он копируется кнопкой.
    expect(find.text('openai/gpt-4o'), findsNothing);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    // Подсказка фильтров уходит в значок рядом с заголовком.
    expect(find.text(l10n.modelPickerFilterHintTools), findsNothing);
    expect(find.byTooltip(l10n.modelPickerFilterHintTools), findsOneWidget);
    // Подпись сортировки не занимает отдельную строку.
    expect(find.text(l10n.modelSortLabel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide window keeps the id and the filter hint', (tester) async {
    final catalog = await _catalog(listed: const [gpt]);
    await _openPicker(
      tester,
      _Host(catalog: catalog, currentId: null, onPicked: _ignorePick),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    expect(find.text('openai/gpt-4o'), findsNothing);
    expect(find.byIcon(Icons.copy_outlined), findsOneWidget);
    expect(find.text(l10n.modelPickerFilterHintTools), findsOneWidget);
    expect(find.text(l10n.modelSortLabel), findsOneWidget);
  });

  testWidgets('on desktop the copy button appears on row hover', (
    tester,
  ) async {
    final catalog = await _catalog(listed: const [gpt]);
    await _openPicker(
      tester,
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: _ignorePick,
        platform: TargetPlatform.linux,
      ),
    );
    final opacity = find
        .ancestor(
          of: find.byIcon(Icons.copy_outlined),
          matching: find.byType(AnimatedOpacity),
        )
        .first;
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);

    final row = find
        .ancestor(of: find.text('GPT-4o'), matching: find.byType(InkWell))
        .first;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(row));
    await tester.pump();

    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
  });

  testWidgets('the full id lives in the copy button tooltip', (tester) async {
    final catalog = await _catalog(listed: const [gpt]);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _openPicker(
      tester,
      _Host(catalog: catalog, currentId: null, onPicked: _ignorePick),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    expect(find.text('openai/gpt-4o'), findsNothing);
    final tooltip = tester.widget<Tooltip>(
      find
          .ancestor(
            of: find.byIcon(Icons.copy_outlined),
            matching: find.byType(Tooltip),
          )
          .first,
    );
    expect(
      tooltip.richMessage?.toPlainText(),
      '${l10n.modelCopyId}\nopenai/gpt-4o',
    );

    await tester.tap(find.byIcon(Icons.copy_outlined));
    await tester.pump();
    expect(copied, 'openai/gpt-4o');
    // CopyButton две секунды показывает галочку: даём таймеру истечь.
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

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
      await _openPicker(
        tester,
        _Host(
          catalog: catalog,
          currentId: 'anthropic/claude',
          onPicked: (value) {
            picked = value;
            closed = true;
          },
        ),
      );
      final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

      expect(find.text(l10n.modelCurrentUnavailable), findsOneWidget);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text(l10n.modelUnavailableBadge), findsOneWidget);

      // Нажатие на недоступную модель не закрывает диалог и ничего не выбирает.
      await tester.tap(find.text('Claude'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(closed, isFalse);

      await tester.tap(find.text('GPT-4o'));
      await tester.pumpAndSettle();
      expect(picked?.id, 'openai/gpt-4o');
    },
  );

  testWidgets('without onTogglePin rows have no pin button', (tester) async {
    final catalog = await _catalog(listed: const [gpt]);
    await _openPicker(
      tester,
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: _ignorePick,
        pinnable: false,
      ),
    );

    expect(find.byIcon(Icons.star_border), findsNothing);
    expect(find.byIcon(Icons.star), findsNothing);
  });

  testWidgets('with onTogglePin rows show the pin button', (tester) async {
    final catalog = await _catalog(listed: const [gpt]);
    await _openPicker(
      tester,
      _Host(catalog: catalog, currentId: null, onPicked: _ignorePick),
    );

    expect(find.byIcon(Icons.star_border), findsOneWidget);
  });

  testWidgets('manage mode: a tap pins and unpins without closing', (
    tester,
  ) async {
    final catalog = await _catalog(listed: const [gpt]);
    final pins = <String>[];
    LlmModelInfo? picked;
    var closed = false;
    await _openPicker(
      tester,
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
    await _openPicker(
      tester,
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: _ignorePick,
        managePins: true,
        requireTools: false,
        pins: pins,
      ),
    );

    await tester.tap(find.text('Plain'));
    await tester.pumpAndSettle();
    expect(pins, ['x/plain']);
  });

  testWidgets('requireTools false lets a model without tools be picked', (
    tester,
  ) async {
    final catalog = await _catalog(listed: const [gpt, plain]);
    LlmModelInfo? picked;
    await _openPicker(
      tester,
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: (value) => picked = value,
        pinnable: false,
        requireTools: false,
      ),
    );

    await tester.tap(find.text('Plain'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'x/plain');
  });

  testWidgets('requireTools true hides models without tools', (tester) async {
    final catalog = await _catalog(listed: const [gpt, plain]);
    await _openPicker(
      tester,
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: _ignorePick,
        pinnable: false,
      ),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    expect(find.text('Plain'), findsNothing);
    expect(find.text(l10n.modelPickerFilterHintTools), findsOneWidget);
  });

  testWidgets('@ suggestions insert the provider filter', (tester) async {
    final catalog = await _catalog(listed: const [gpt, claude]);
    await _openPicker(
      tester,
      _Host(catalog: catalog, currentId: null, onPicked: _ignorePick),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    await tester.enterText(find.byType(AppTextField), '@pro');
    await tester.pumpAndSettle();
    expect(find.text(l10n.modelFilterProvider), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    // Подсказка вставила `@provider:` и сразу показала провайдеров по алфавиту.
    expect(_searchText(tester), '@provider:');
    expect(find.text('anthropic'), findsWidgets);
    expect(find.text('openai'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(_searchText(tester), '@provider:"openai" ');
    expect(find.text('GPT-4o'), findsOneWidget);
    expect(find.text('Claude'), findsNothing);
  });

  testWidgets('a provider filter token narrows the list', (tester) async {
    final catalog = await _catalog(listed: const [gpt, claude, llama]);
    await _openPicker(
      tester,
      _Host(catalog: catalog, currentId: null, onPicked: _ignorePick),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    await tester.enterText(find.byType(AppTextField), '@provider:openai');
    await tester.pumpAndSettle();

    expect(find.text('GPT-4o'), findsOneWidget);
    expect(find.text('Claude'), findsNothing);
    expect(find.text('Llama'), findsNothing);
    expect(find.text(l10n.modelPickerResultCount(1, 3)), findsOneWidget);
  });

  testWidgets('an unknown provider is reported and not applied', (
    tester,
  ) async {
    final catalog = await _catalog(listed: const [gpt, claude]);
    await _openPicker(
      tester,
      _Host(catalog: catalog, currentId: null, onPicked: _ignorePick),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    await tester.enterText(find.byType(AppTextField), '@provider:nope');
    await tester.pumpAndSettle();

    expect(find.text(l10n.modelPickerProviderUnknown('nope')), findsOneWidget);
    expect(find.text('GPT-4o'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
  });

  testWidgets('@free keeps only free models', (tester) async {
    final catalog = await _catalog(listed: const [gpt, freeModel]);
    await _openPicker(
      tester,
      _Host(catalog: catalog, currentId: null, onPicked: _ignorePick),
    );

    await tester.enterText(find.byType(AppTextField), '@free');
    await tester.pumpAndSettle();

    expect(find.text('Free'), findsOneWidget);
    expect(find.text('GPT-4o'), findsNothing);
  });

  testWidgets('Enter picks the first match when nothing is highlighted', (
    tester,
  ) async {
    final catalog = await _catalog(listed: const [gpt, claude]);
    LlmModelInfo? picked;
    await _openPicker(
      tester,
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: (value) => picked = value,
      ),
    );

    await tester.enterText(find.byType(AppTextField), 'claude');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(picked?.id, 'anthropic/claude');
  });

  testWidgets('the sort is remembered through the store', (tester) async {
    final settings = MemoryClientSettings();
    final store = ModelPickerSortStore(settings);
    final catalog = await _catalog(listed: const [gpt]);
    await _openPicker(
      tester,
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: _ignorePick,
        sortStore: store,
      ),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    expect(_sortValue(tester), l10n.modelSortProvider);

    await tester.tap(find.byType(AppSelect<ModelSort>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.modelSortPrice).last);
    await tester.pumpAndSettle();

    expect(_sortValue(tester), l10n.modelSortPrice);
    expect(await store.load(), ModelSort.price);
    expect(settings.values[ClientSettingsKeys.modelSort], 'price');
  });

  testWidgets('a stored sort is applied on open', (tester) async {
    final store = ModelPickerSortStore(MemoryClientSettings());
    await store.save(ModelSort.name);
    final catalog = await _catalog(listed: const [gpt]);
    await _openPicker(
      tester,
      _Host(
        catalog: catalog,
        currentId: null,
        onPicked: _ignorePick,
        sortStore: store,
      ),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    expect(_sortValue(tester), l10n.modelSortName);
  });

  testWidgets('an empty result can be reset', (tester) async {
    final catalog = await _catalog(listed: const [gpt, claude]);
    await _openPicker(
      tester,
      _Host(catalog: catalog, currentId: null, onPicked: _ignorePick),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    await tester.enterText(find.byType(AppTextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text(l10n.modelPickerEmpty), findsOneWidget);

    await tester.tap(find.text(l10n.modelPickerResetFilters));
    await tester.pumpAndSettle();

    expect(find.text('GPT-4o'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
  });

  testWidgets('closing the picker keeps the old choice', (tester) async {
    final catalog = await _catalog(listed: const [gpt]);
    LlmModelInfo? picked = gpt;
    await _openPicker(
      tester,
      _Host(
        catalog: catalog,
        currentId: 'openai/gpt-4o',
        onPicked: (value) => picked = value,
      ),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(Dialog)));

    await tester.tap(find.byTooltip(l10n.commonClose));
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });

  testWidgets('runtime action loads an unloaded model', (tester) async {
    final catalog = await _catalog(listed: const [gpt]);
    final runtime = _FakeRuntime(
      ModelRuntimeState(
        providers: {
          'test': ProviderRuntimeState(
            providerId: 'test',
            capabilities: ModelRuntimeCapabilities.full,
            models: {
              gpt.id: ModelRuntime(
                modelId: gpt.id,
                phase: ModelRuntimePhase.unloaded,
              ),
            },
          ),
        },
      ),
    );
    await _openPicker(
      tester,
      _Host(
        catalog: catalog,
        currentId: null,
        runtime: runtime,
        onPicked: _ignorePick,
      ),
    );

    await tester.tap(find.byTooltip('Load'));
    await tester.pumpAndSettle();
    expect(runtime.loaded, [gpt.id]);
  });
}

void _ignorePick(LlmModelInfo? _) {
  return;
}
