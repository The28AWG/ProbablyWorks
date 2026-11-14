import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/file_secret_store.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';
import 'package:pw_agent/providers/ai/provider_settings_store.dart';
import 'package:test/test.dart';

void main() {
  late SettingsRepository settings;
  late MemorySecretStore secrets;
  late LlmProviderSettingsStore store;

  setUp(() {
    final db = openInMemoryDatabase();
    addTearDown(db.close);
    settings = SettingsRepository(db);
    secrets = MemorySecretStore();
    store = LlmProviderSettingsStore(settings, secrets);
  });

  test('new provider gets defaults from its descriptor', () async {
    final config = await store.read(llamaCppDescriptor);

    expect(config.enabled, isTrue);
    expect(config.baseUrl, llamaCppDefaultBaseUrl);
    expect(config.hasApiKey, isFalse);
  });

  test('reads legacy llama.cpp settings', () async {
    await settings.write(SettingsRepository.keyLlamaCppEnabled, 'false');
    await settings.write(
      SettingsRepository.keyLlamaCppBaseUrl,
      'http://127.0.0.1:9000',
    );
    await secrets.write(llamaCppKeyName, 'secret-key');

    final config = await store.read(llamaCppDescriptor);

    expect(config.enabled, isFalse);
    expect(config.baseUrl, 'http://127.0.0.1:9000');
    expect(config.apiKeyTail, 'key');
  });

  test(
    'saving a provider setting uses generic keys and drops legacy ones',
    () async {
      await secrets.write(llamaCppKeyName, 'old-key');

      await store.setEnabled(llamaCppDescriptor, false);
      await store.saveBaseUrl(llamaCppDescriptor, 'http://127.0.0.1:9000');
      await store.saveApiKey(llamaCppDescriptor, 'new-key');

      expect(
        await settings.read(providerSettingKey(llamaCppProviderId, 'enabled')),
        'false',
      );
      expect(
        await settings.read(providerSettingKey(llamaCppProviderId, 'baseUrl')),
        'http://127.0.0.1:9000',
      );
      expect(
        await settings.read(SettingsRepository.keyLlamaCppEnabled),
        isNull,
      );
      expect(
        await settings.read(SettingsRepository.keyLlamaCppBaseUrl),
        isNull,
      );
      expect(await secrets.read(llamaCppKeyName), isNull);
      expect(
        await secrets.read(providerApiKeyName(llamaCppProviderId)),
        'new-key',
      );
    },
  );

  test('any provider key can come from the environment', () {
    final environment = {
      'PROBABLY_WORKS_LLAMACPP_KEY': 'llama-key',
      'PROBABLY_WORKS_OPENROUTER_KEY': 'openrouter-key',
    };

    expect(
      secretFromEnvironment(
        providerApiKeyName(llamaCppProviderId),
        environment,
      ),
      'llama-key',
    );
    expect(
      secretFromEnvironment(
        providerApiKeyName(openRouterProviderId),
        environment,
      ),
      'openrouter-key',
    );
  });

  test('OpenRouter keeps its legacy environment name', () {
    const environment = {'OPENROUTER_API_KEY': 'legacy-key'};

    expect(secretFromEnvironment(openRouterKeyName, environment), 'legacy-key');
  });

  test('a provider without a key reports no key', () async {
    final status = await store.readStatus(openRouterDescriptor);

    expect(status.apiKeySet, isFalse);
    expect(status.apiKeyTail, isEmpty);
    expect(status.available, isFalse);
    expect(status.checkedAt, isNull);
  });
}
