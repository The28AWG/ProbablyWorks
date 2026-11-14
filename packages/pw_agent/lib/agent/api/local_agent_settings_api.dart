import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

/// Локальные настройки агента.
@LazySingleton(as: AgentSettingsApi)
final class LocalAgentSettingsApi
    implements AgentSettingsApi, LlamaCppSettingsApi {
  LocalAgentSettingsApi(this._settings, this._secrets, this._catalog);

  final SettingsRepository _settings;
  final SecretStore _secrets;
  final ModelCatalogService _catalog;

  @override
  Future<AgentSettingsSnapshot> load() async {
    final key = await _secrets.read(openRouterKeyName);
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
      apiKeyTail: _tailOf(key),
      catalog: _catalog.state,
      llamaCpp: _catalog.state.llamaCpp,
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
  Future<void> saveApiKey(String key) async {
    final previous = await _secrets.read(openRouterKeyName);
    await _secrets.write(openRouterKeyName, key);
    try {
      await _catalog.checkKey();
    } on Object {
      if (previous == null) {
        await _secrets.delete(openRouterKeyName);
      } else {
        await _secrets.write(openRouterKeyName, previous);
      }
      rethrow;
    }
  }

  @override
  Future<void> deleteApiKey() => _secrets.delete(openRouterKeyName);

  @override
  Future<LlmKeyInfo?> checkKey() async {
    final key = await _secrets.read(openRouterKeyName);
    if (key == null || key.isEmpty) return null;
    return _catalog.checkKey();
  }

  @override
  Future<void> refreshModels() => _catalog.refresh();

  @override
  Future<void> rememberModels(List<String> ids) => _catalog.remember(ids);

  @override
  Future<void> saveLlamaCppBaseUrl(String baseUrl) async {
    final trimmed = baseUrl.trim();
    await _settings.write(
      SettingsRepository.keyLlamaCppBaseUrl,
      trimmed.isEmpty ? null : trimmed,
    );
  }

  @override
  Future<void> saveLlamaCppApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return;
    await _secrets.write(llamaCppKeyName, trimmed);
  }

  @override
  Future<void> deleteLlamaCppApiKey() => _secrets.delete(llamaCppKeyName);

  @override
  Future<void> setLlamaCppEnabled(bool enabled) => _settings.write(
    SettingsRepository.keyLlamaCppEnabled,
    enabled ? null : 'false',
  );

  @override
  Future<LlamaCppStatus?> checkLlamaCpp() => _catalog.checkLlamaCpp();

  static String _tailOf(String? key) {
    if (key == null || key.isEmpty) return '';
    final runes = key.runes.toList();
    return String.fromCharCodes(
      runes.skip(runes.length > 3 ? runes.length - 3 : 0),
    );
  }
}
