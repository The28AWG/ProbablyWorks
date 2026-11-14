import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/llm_provider_registry.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/provider_settings_store.dart';

/// Локальные настройки агента.
@LazySingleton(as: AgentSettingsApi)
final class LocalAgentSettingsApi implements AgentSettingsApi {
  LocalAgentSettingsApi(
    this._settings,
    this._catalog,
    this._registry,
    this._providers,
  );

  final SettingsRepository _settings;
  final ModelCatalogService _catalog;
  final LlmProviderRegistry _registry;
  final LlmProviderSettingsStore _providers;

  @override
  Future<AgentSettingsSnapshot> load() async {
    // Конфиг провайдеров нужен до первого кадра настроек: без сети.
    await _catalog.loadProviderConfigs();
    return AgentSettingsSnapshot(
      defaultModel:
          await _settings.read(SettingsRepository.keyDefaultModel) ?? '',
      titleModel: await _settings.read(SettingsRepository.keyTitleModel) ?? '',
      memoryModel:
          await _settings.read(SettingsRepository.keyMemoryModel) ?? '',
      subagentModel:
          await _settings.read(SettingsRepository.keySubagentModel) ?? '',
      fallbackModel:
          await _settings.read(SettingsRepository.keyFallbackModel) ?? '',
      defaultPolicy:
          await _settings.read(SettingsRepository.keyDefaultPolicy) ?? 'ask',
      denylist: await _settings.readDenylist(),
      securityProfile: await _settings.readSecurityProfile(),
      limits: await _settings.limits(),
      pinnedModels: await _settings.readPinnedModels(),
      stepsDisplay: await _settings.readStepsDisplay(),
      catalog: _catalog.state,
    );
  }

  @override
  Stream<ModelCatalogState> watchCatalog() => _catalog.watch();

  @override
  Stream<List<String>> watchPinnedModels() => _settings
      .watch(SettingsRepository.keyPinnedModels)
      .asyncMap((_) => _settings.readPinnedModels());

  @override
  Future<void> writeSetting(String key, String? value) =>
      _settings.write(key, value);

  @override
  Future<void> saveStepsDisplay(StepsDisplay value) =>
      _settings.saveStepsDisplay(value);

  @override
  Future<void> savePinnedModels(List<String> ids) =>
      _settings.savePinnedModels(ids);

  @override
  Future<void> saveDenylist(List<String> patterns) =>
      _settings.saveDenylist(patterns);

  @override
  Future<void> saveSecurityProfile(SecurityProfile profile) =>
      _settings.saveSecurityProfile(profile);

  @override
  Future<void> saveLimits(AppLimits limits) => _settings.saveLimits(limits);

  @override
  Future<void> refreshModels() => _catalog.refresh();

  @override
  Future<void> rememberModels(List<String> ids) => _catalog.remember(ids);

  @override
  Future<List<LlmProviderStatus>> providerStatuses() =>
      _registry.configStatuses();

  @override
  Future<LlmProviderStatus> checkProvider(String providerId) async {
    final status = await _catalog.checkProvider(providerId);
    if (status == null) {
      throw LlmFailure('Unknown AI provider: $providerId');
    }
    return status;
  }

  @override
  Future<void> saveProviderBaseUrl(String providerId, String? baseUrl) async {
    final descriptor = _descriptorOf(providerId);
    await _providers.saveBaseUrl(descriptor, baseUrl);
    await _catalog.loadProviderConfigs();
  }

  @override
  Future<LlmProviderStatus> saveProviderApiKey(
    String providerId,
    String key,
  ) async {
    final descriptor = _descriptorOf(providerId);
    final previous = (await _providers.read(descriptor)).apiKey;
    await _providers.saveApiKey(descriptor, key);
    final status = await _catalog.checkProvider(providerId);
    if (descriptor.requiresApiKey &&
        (status == null || !status.apiKeySet || status.error != null)) {
      await _restoreKey(descriptor, previous);
      await _catalog.loadProviderConfigs();
      throw LlmFailure(status?.error ?? 'The API key was rejected');
    }
    await _catalog.loadProviderConfigs();
    return status ?? await _providers.readStatus(descriptor);
  }

  @override
  Future<void> deleteProviderApiKey(String providerId) async {
    final descriptor = _descriptorOf(providerId);
    await _providers.deleteApiKey(descriptor);
    await _catalog.loadProviderConfigs();
  }

  @override
  Future<void> setProviderEnabled(String providerId, bool enabled) async {
    final descriptor = _descriptorOf(providerId);
    await _providers.setEnabled(descriptor, enabled);
    await _catalog.loadProviderConfigs();
  }

  LlmProviderDescriptor _descriptorOf(String providerId) {
    final descriptor = _registry.descriptorById(providerId);
    if (descriptor == null) {
      throw LlmFailure('Unknown AI provider: $providerId');
    }
    return descriptor;
  }

  /// Возвращает прежний ключ после отказа сервиса. Пустой ключ удаляется.
  Future<void> _restoreKey(
    LlmProviderDescriptor descriptor,
    String? previous,
  ) async {
    if (previous == null || previous.isEmpty) {
      await _providers.deleteApiKey(descriptor);
    } else {
      await _providers.saveApiKey(descriptor, previous);
    }
  }
}
