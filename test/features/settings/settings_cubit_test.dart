import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/settings/presentation/bloc/settings_cubit.dart';
import 'package:pw_agent/agent/api/local_agent_settings_api.dart';
import 'package:pw_agent/core/data/saved_model_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/llm_provider_registry.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/model_runtime_service.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';
import 'package:pw_agent/providers/ai/provider_settings_store.dart';

const _key = 'sk-or-v1-secret-abc';

/// Провайдер OpenRouter без сети: читает ключ из хранилища и принимает его,
/// пока [accept] = true.
class _EmptyLocalModels implements LocalModelsSource {
  @override
  LocalModelsState get state => const LocalModelsState();

  @override
  Stream<LocalModelsState> watch() => Stream.value(state);

  @override
  Future<void> refresh() => Future<void>.value();

  @override
  Future<String> startInstall(
    String source, {
    String? name,
    String? sha256,
  }) async => '';

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

class _KeyLlm extends LlmProviderBase {
  _KeyLlm(this.secrets) : super(openRouterDescriptor);

  final MemorySecretStore secrets;
  bool accept = true;

  @override
  Future<List<LlmProviderStatus>> configStatuses() async {
    final key = await secrets.read(providerApiKeyName(openRouterProviderId));
    return [
      LlmProviderStatus(
        id: openRouterProviderId,
        apiKeySet: key != null && key.isNotEmpty,
        apiKeyTail: key == null || key.isEmpty ? '' : charSuffix(key, 3),
      ),
    ];
  }

  @override
  Future<List<LlmProviderStatus>> statuses() async {
    final base = (await configStatuses()).single;
    final now = DateTime.utc(2026, 11, 14);
    if (!base.apiKeySet) {
      return [
        base.copyWith(error: 'OpenRouter API key is not set', checkedAt: now),
      ];
    }
    if (!accept) {
      return [base.copyWith(error: 'invalid key', checkedAt: now)];
    }
    return [
      base.copyWith(
        available: true,
        checkedAt: now,
        keyInfo: LlmKeyInfo(
          label: 'sk-or-v1-...abc',
          usage: 12.5,
          limit: 50,
          limitRemaining: 37.5,
          limitReset: 'monthly',
          expiresAt: DateTime.utc(2027, 12, 31),
        ),
      ),
    ];
  }

  @override
  Future<List<LlmModelInfo>> listModels() async => const [
    LlmModelInfo(id: 'openai/gpt-4o', name: 'GPT-4o', supportsTools: true),
  ];

  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      throw UnimplementedError('not used by settings');
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late MemoryClientSettings clientSettings;
  late MemorySecretStore secrets;
  late _KeyLlm llm;
  late ModelCatalogService catalog;
  late LocalAgentSettingsApi settingsApi;
  late ThemeController theme;
  late SettingsCubit cubit;

  setUp(() {
    db = openInMemoryDatabase();
    settings = SettingsRepository(db);
    clientSettings = MemoryClientSettings();
    secrets = MemorySecretStore();
    llm = _KeyLlm(secrets);
    catalog = ModelCatalogService(
      SavedModelRepository(db),
      LlmProviderRegistry([llm]),
    );
    final registry = LlmProviderRegistry([llm]);
    settingsApi = LocalAgentSettingsApi(
      settings,
      catalog,
      registry,
      LlmProviderSettingsStore(settings, secrets),
      ModelRuntimeService(registry),
      _EmptyLocalModels(),
    );
    theme = ThemeController();
    cubit = SettingsCubit(
      clientSettings,
      settingsApi,
      LocaleController(),
      theme,
    );
  });

  tearDown(() async {
    await cubit.close();
    await db.close();
  });

  test('a saved key shows only its last three characters', () async {
    await cubit.load();
    await cubit.saveProviderApiKey(openRouterProviderId, _key);

    final status = cubit.state.catalog.providerStatuses[openRouterProviderId]!;
    expect(status.apiKeySet, isTrue);
    expect(status.apiKeyTail, 'abc');
    // Полный ключ остаётся только в защищённом хранилище, но не в состоянии экрана.
    expect(await secrets.read(providerApiKeyName(openRouterProviderId)), _key);
    expect(cubit.state.props.any((value) => '$value'.contains(_key)), isFalse);
  });

  test('a rejected key is not saved and the previous one stays', () async {
    await cubit.load();
    await cubit.saveProviderApiKey(openRouterProviderId, _key);

    llm.accept = false;
    await cubit.saveProviderApiKey(openRouterProviderId, 'sk-or-v1-broken-xyz');

    expect(cubit.state.providerErrors[openRouterProviderId], isNotNull);
    expect(await secrets.read(providerApiKeyName(openRouterProviderId)), _key);
    expect(
      cubit.state.catalog.providerStatuses[openRouterProviderId]!.apiKeyTail,
      'abc',
    );
  });

  test('a successful check stores the key details', () async {
    await cubit.load();
    await cubit.saveProviderApiKey(openRouterProviderId, _key);

    final info =
        cubit.state.catalog.providerStatuses[openRouterProviderId]!.keyInfo!;
    expect(info.usage, 12.5);
    expect(info.limit, 50);
    expect(info.limitRemaining, 37.5);
    expect(info.expiresAt, DateTime.utc(2027, 12, 31));
  });

  test('a failed check keeps the last details and reports the error', () async {
    await cubit.load();
    await cubit.saveProviderApiKey(openRouterProviderId, _key);
    final before =
        cubit.state.catalog.providerStatuses[openRouterProviderId]!.keyInfo;

    llm.accept = false;
    await cubit.checkProvider(openRouterProviderId);

    final status = cubit.state.catalog.providerStatuses[openRouterProviderId]!;
    expect(status.error, isNotNull);
    expect(status.keyInfo, before);
  });

  test('deleteProviderApiKey removes the key and its details', () async {
    await cubit.load();
    await cubit.saveProviderApiKey(openRouterProviderId, _key);

    await cubit.deleteProviderApiKey(openRouterProviderId);

    final status = cubit.state.catalog.providerStatuses[openRouterProviderId]!;
    expect(status.apiKeySet, isFalse);
    expect(status.apiKeyTail, isEmpty);
    expect(status.keyInfo, isNull);
    expect(
      await secrets.read(providerApiKeyName(openRouterProviderId)),
      isNull,
    );
  });

  test('pinned models changed in the repository reach the cubit', () async {
    await cubit.load();

    final pinned = cubit.stream
        .map((state) => state.pinnedModels)
        .firstWhere((pins) => pins.contains('openai/gpt-4o'))
        .timeout(const Duration(seconds: 5));
    await settings.savePinnedModels(['openai/gpt-4o']);

    expect(await pinned, ['openai/gpt-4o']);
  });

  test('a setting written outside the cubit reloads the page', () async {
    await cubit.load();
    expect(cubit.state.defaultModel, isEmpty);

    final updated = cubit.stream
        .map((state) => state.defaultModel)
        .firstWhere((model) => model == 'openai/gpt-4o')
        .timeout(const Duration(seconds: 5));
    await settings.write(SettingsRepository.keyDefaultModel, 'openai/gpt-4o');

    expect(await updated, 'openai/gpt-4o');
  });

  test('theme mode is saved, applied and loaded back', () async {
    await cubit.load();

    await cubit.saveThemeMode(ThemeMode.dark);

    expect(cubit.state.themeMode, ThemeMode.dark);
    expect(theme.value, ThemeMode.dark);
    expect(await clientSettings.read(ClientSettingsKeys.themeMode), 'dark');

    final reopened = SettingsCubit(
      clientSettings,
      settingsApi,
      LocaleController(),
      ThemeController(),
    );
    addTearDown(reopened.close);
    await reopened.load();
    expect(reopened.state.themeMode, ThemeMode.dark);
  });
  test(
    'resetClientPreferences clears interface keys and applies defaults',
    () async {
      clientSettings.values.addAll({
        ClientSettingsKeys.language: 'ru',
        ClientSettingsKeys.themeMode: 'dark',
        ClientSettingsKeys.sidebarWidth: '320',
        ClientSettingsKeys.keybindings: '{"chat.new":"ctrl+n"}',
        ClientSettingsKeys.modelSort: 'price',
        ClientSettingsKeys.agentProfiles: '[]',
      });
      await cubit.load();

      await cubit.resetClientPreferences();

      for (final key in ClientSettingsKeys.interfacePreferences) {
        expect(await clientSettings.read(key), isNull, reason: key);
      }
      expect(cubit.state.language, 'system');
      expect(cubit.state.themeMode, ThemeMode.system);
      // Сброс не должен выглядеть как сохранение и вызывать чужой снекбар.
      expect(cubit.state.saved, 0);
      expect(theme.value, ThemeMode.system);
      expect(await clientSettings.read(ClientSettingsKeys.agentProfiles), '[]');
    },
  );
}
