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
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

const _key = 'sk-or-v1-secret-abc';

/// Сервис ключей: принимает ключ, пока [accept] = true; иначе отвечает ошибкой авторизации.
class _KeyLlm implements LlmProvider {
  bool accept = true;

  @override
  Future<LlmKeyInfo> checkKey() async {
    if (!accept) throw const LlmFailure('invalid key', statusCode: 401);
    return LlmKeyInfo(
      label: 'sk-or-v1-...abc',
      usage: 12.5,
      limit: 50,
      limitRemaining: 37.5,
      limitReset: 'monthly',
      expiresAt: DateTime.utc(2027, 12, 31),
    );
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
  late ThemeController theme;
  late SettingsCubit cubit;

  setUp(() {
    db = openInMemoryDatabase();
    settings = SettingsRepository(db);
    clientSettings = MemoryClientSettings();
    secrets = MemorySecretStore();
    llm = _KeyLlm();
    catalog = ModelCatalogService(SavedModelRepository(db), llm);
    theme = ThemeController();
    cubit = SettingsCubit(
      clientSettings,
      LocalAgentSettingsApi(settings, secrets, catalog),
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
    await cubit.saveApiKey(_key);

    expect(cubit.state.apiKeySet, isTrue);
    expect(cubit.state.apiKeyTail, 'abc');
    // Полный ключ остаётся только в защищённом хранилище, но не в состоянии экрана.
    expect(await secrets.read(openRouterKeyName), _key);
    expect(cubit.state.props.any((value) => '$value'.contains(_key)), isFalse);
  });

  test('a rejected key is not saved and the previous one stays', () async {
    await cubit.load();
    await cubit.saveApiKey(_key);

    llm.accept = false;
    await cubit.saveApiKey('sk-or-v1-broken-xyz');

    expect(cubit.state.keyError, isNotNull);
    expect(await secrets.read(openRouterKeyName), _key);
    expect(cubit.state.apiKeyTail, 'abc');
  });

  test('a successful check stores the key details', () async {
    await cubit.load();
    await cubit.saveApiKey(_key);

    final info = cubit.state.keyInfo!;
    expect(info.usage, 12.5);
    expect(info.limit, 50);
    expect(info.limitRemaining, 37.5);
    expect(info.expiresAt, DateTime.utc(2027, 12, 31));
    expect(cubit.state.keyInfoError, isNull);
  });

  test(
    'a failed refresh keeps the last details and reports the error',
    () async {
      await cubit.load();
      await cubit.saveApiKey(_key);
      final before = cubit.state.keyInfo;

      llm.accept = false;
      await cubit.refreshKeyInfo();

      expect(cubit.state.keyInfoLoading, isFalse);
      expect(cubit.state.keyInfoError, isNotNull);
      expect(cubit.state.keyInfo, before);
    },
  );

  test('deleteApiKey removes the key and its details', () async {
    await cubit.load();
    await cubit.saveApiKey(_key);

    await cubit.deleteApiKey();

    expect(cubit.state.apiKeySet, isFalse);
    expect(cubit.state.apiKeyTail, isEmpty);
    expect(cubit.state.keyInfo, isNull);
    expect(await secrets.read(openRouterKeyName), isNull);
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

  test('theme mode is saved, applied and loaded back', () async {
    await cubit.load();

    await cubit.saveThemeMode(ThemeMode.dark);

    expect(cubit.state.themeMode, ThemeMode.dark);
    expect(theme.value, ThemeMode.dark);
    expect(await clientSettings.read(ClientSettingsKeys.themeMode), 'dark');

    final reopened = SettingsCubit(
      clientSettings,
      LocalAgentSettingsApi(settings, secrets, catalog),
      LocaleController(),
      ThemeController(),
    );
    addTearDown(reopened.close);
    await reopened.load();
    expect(reopened.state.themeMode, ThemeMode.dark);
  });
}
