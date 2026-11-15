import 'dart:async';

import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/settings/presentation/widgets/local_model_dialogs.dart';
import 'package:probably_works/features/settings/presentation/widgets/local_models_section.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/llamadart/llamadart_connection.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

final class _FakeSource implements LocalModelsSource {
  _FakeSource(this._state);

  final LocalModelsState _state;
  final installs = <String>[];
  final deleted = <String>[];
  final imports = <String>[];
  var autoUnload = -1;
  var cleared = 0;
  LocalModelSettings? settings;

  @override
  LocalModelsState get state => _state;

  @override
  Stream<LocalModelsState> watch() => Stream.value(_state);

  @override
  Future<void> refresh() => Future<void>.value();

  Future<String> install(String source, {String? name, String? sha256}) =>
      startInstall(source, name: name, sha256: sha256);

  @override
  Future<String> startInstall(
    String source, {
    String? name,
    String? sha256,
  }) async {
    installs.add(source);
    return 'id';
  }

  @override
  Future<void> cancelInstall(String id) => Future<void>.value();

  @override
  Future<String> importPath(String path, {String? name}) async {
    imports.add(path);
    return 'id';
  }

  @override
  Future<void> delete(String id) async => deleted.add(id);

  @override
  Future<void> updateSettings(String id, LocalModelSettings value) async {
    settings = value;
  }

  @override
  Future<void> clearCache() async => cleared++;

  @override
  Future<void> saveAutoUnload(int minutes) async => autoUnload = minutes;
}

/// Источник с живым потоком: проверяет, что карточка скачивания и прогресс
/// приходят из подписки, а не только из снимка при открытии раздела.
final class _StreamingSource implements LocalModelsSource {
  _StreamingSource(this._state);

  final _changes = StreamController<LocalModelsState>.broadcast();
  LocalModelsState _state;

  void publish(LocalModelsState state) {
    _state = state;
    _changes.add(state);
  }

  @override
  LocalModelsState get state => _state;

  @override
  Stream<LocalModelsState> watch() => Stream.multi((controller) {
    controller.add(_state);
    final sub = _changes.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  @override
  Future<void> refresh() => Future<void>.value();

  Future<String> install(String source, {String? name, String? sha256}) =>
      startInstall(source, name: name, sha256: sha256);

  @override
  Future<String> startInstall(
    String source, {
    String? name,
    String? sha256,
  }) async {
    publish(
      LocalModelsState(
        downloads: [
          LocalModelDownload(
            id: 'd',
            name: 'Qwen 4B',
            source: source,
            receivedBytes: 10,
            totalBytes: 100,
          ),
        ],
      ),
    );
    return 'd';
  }

  @override
  Future<void> cancelInstall(String id) => Future<void>.value();

  @override
  Future<String> importPath(String path, {String? name}) async => '';

  @override
  Future<void> delete(String id) => Future<void>.value();

  @override
  Future<void> updateSettings(String id, LocalModelSettings settings) =>
      Future<void>.value();

  @override
  Future<void> clearCache() => Future<void>.value();

  @override
  Future<void> saveAutoUnload(int minutes) => Future<void>.value();
}

final class _FakeRuntime implements ModelRuntimeSource {
  _FakeRuntime([this._state = const ModelRuntimeState()]);

  final ModelRuntimeState _state;

  @override
  ModelRuntimeState get runtime => _state;

  @override
  Stream<ModelRuntimeState> watchRuntime() => Stream.value(_state);

  @override
  Future<void> refreshRuntime() => Future<void>.value();

  @override
  Future<void> loadModel(String modelId) => Future<void>.value();

  @override
  Future<void> unloadModel(String modelId) => Future<void>.value();
}

LocalModelFile _model() => LocalModelFile(
  id: 'qwen',
  name: 'Qwen 4B',
  source: 'hf://owner/repo/qwen.gguf',
  sourceKind: LocalModelSourceKind.huggingFace,
  cacheKey: 'cache',
  path: '/models/qwen.gguf',
  sizeBytes: 2 * 1024 * 1024 * 1024,
  settings: const LocalModelSettings(contextSize: 8192),
  createdAt: DateTime.utc(2026),
);

Future<void> _pump(
  WidgetTester tester,
  LocalModelsState state, {
  ModelRuntimeState runtime = const ModelRuntimeState(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: LocalModelsSection(
            source: _FakeSource(state),
            runtime: _FakeRuntime(runtime),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty state invites installing a model', (tester) async {
    await _pump(tester, const LocalModelsState());

    final l10n = AppLocalizations.of(
      tester.element(find.byType(LocalModelsSection)),
    );
    expect(find.text(l10n.localModelsTitle), findsOneWidget);
    expect(find.text(l10n.localModelsEmptyTitle), findsOneWidget);
    expect(find.text(l10n.localModelsInstall), findsWidgets);
  });

  testWidgets('unsupported server hides the install action', (tester) async {
    await _pump(tester, const LocalModelsState(supported: false));

    final l10n = AppLocalizations.of(
      tester.element(find.byType(LocalModelsSection)),
    );
    expect(find.text(l10n.localModelsUnsupported), findsOneWidget);
    expect(find.text(l10n.localModelsInstall), findsNothing);
  });

  testWidgets('installed model shows parameters and the loaded state', (
    tester,
  ) async {
    const runtime = ModelRuntimeState(
      providers: {
        llamadartProviderId: ProviderRuntimeState(
          providerId: llamadartProviderId,
          models: {
            'llamadart:qwen': ModelRuntime(
              modelId: 'llamadart:qwen',
              phase: ModelRuntimePhase.loaded,
            ),
          },
        ),
      },
    );
    await _pump(tester, LocalModelsState(models: [_model()]), runtime: runtime);

    final l10n = AppLocalizations.of(
      tester.element(find.byType(LocalModelsSection)),
    );
    expect(find.text('Qwen 4B'), findsOneWidget);
    expect(find.text('8192 ctx'), findsOneWidget);
    expect(find.text(l10n.localModelsStorage('2.0 GB')), findsOneWidget);
    expect(find.byTooltip(l10n.modelRuntimeUnload), findsOneWidget);
  });

  testWidgets('download card appears and follows the source stream', (
    tester,
  ) async {
    final source = _StreamingSource(const LocalModelsState());
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: LocalModelsSection(source: source, runtime: _FakeRuntime()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Пользователь открывает диалог и подтверждает установку не в том же
    // микротаске, что подписка на источник.
    await tester.pump(const Duration(milliseconds: 100));

    await source.install('hf://owner/repo/qwen.gguf');
    await tester.pump();
    await tester.pump();

    expect(find.text('Qwen 4B'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.1, 0.001));

    source.publish(
      const LocalModelsState(
        downloads: [
          LocalModelDownload(
            id: 'd',
            name: 'Qwen 4B',
            source: 'hf://owner/repo/qwen.gguf',
            receivedBytes: 50,
            totalBytes: 100,
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      closeTo(0.5, 0.001),
    );
  });

  testWidgets('auto-unload menu saves the selected value', (tester) async {
    final source = _FakeSource(const LocalModelsState());
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: LocalModelsSection(source: source, runtime: _FakeRuntime()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownMenu<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 min').last);
    await tester.pumpAndSettle();

    expect(source.autoUnload, 30);
  });

  testWidgets('install dialog returns the entered source', (tester) async {
    LocalModelInstallRequest? result;
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
                onPressed: () async {
                  result = await showDialog<LocalModelInstallRequest>(
                    context: context,
                    builder: (_) => const LocalModelInstallDialog(),
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
    await tester.enterText(
      find.byType(AppTextField).first,
      'hf://owner/repo/model.gguf',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Install model'),
      ),
    );
    await tester.pumpAndSettle();

    expect(result?.source, 'hf://owner/repo/model.gguf');
    expect(result?.name, isNull);
  });

  testWidgets('settings dialog returns changed parameters', (tester) async {
    LocalModelSettings? result;
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
                onPressed: () async {
                  result = await showDialog<LocalModelSettings>(
                    context: context,
                    builder: (_) => const LocalModelSettingsDialog(
                      modelName: 'Qwen',
                      initial: LocalModelSettings(contextSize: 4096),
                    ),
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
    await tester.enterText(find.byType(AppTextField).first, '8192');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result?.contextSize, 8192);
  });
}
