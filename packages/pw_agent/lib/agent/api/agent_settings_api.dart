import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

/// Снимок настроек агента. Язык и тема сюда не входят: это настройки клиента.
final class AgentSettingsSnapshot {
  const AgentSettingsSnapshot({
    required this.defaultModel,
    required this.titleModel,
    required this.memoryModel,
    required this.subagentModel,
    required this.fallbackModel,
    required this.defaultPolicy,
    required this.denylist,
    required this.securityProfile,
    required this.limits,
    required this.pinnedModels,
    required this.stepsDisplay,
    required this.catalog,
  });

  final String defaultModel;
  final String titleModel;
  final String memoryModel;
  final String subagentModel;
  final String fallbackModel;
  final String defaultPolicy;
  final List<String> denylist;
  final SecurityProfile securityProfile;
  final AppLimits limits;
  final List<String> pinnedModels;
  final StepsDisplay stepsDisplay;

  /// Каталог содержит дескрипторы провайдеров и их статусы. Отдельных
  /// полей под конкретного провайдера в снимке нет.
  final ModelCatalogState catalog;
}

/// Настройки провайдеров, общие для локального и удалённого агента.
///
/// Один интерфейс на всех провайдеров: новый провайдер не добавляет
/// методов в API, сервер и клиент. id приходит из
/// [LlmProviderDescriptor.id].
abstract interface class LlmProviderSettingsApi {
  /// Статусы без обращения к сети: включённость, адрес, наличие ключа.
  Future<List<LlmProviderStatus>> providerStatuses();

  /// Проверка одного провайдера с обращением к сервису.
  Future<LlmProviderStatus> checkProvider(String providerId);

  /// Сохраняет адрес сервера. Null или пустая строка — значение по умолчанию.
  Future<void> saveProviderBaseUrl(String providerId, String? baseUrl);

  /// Сохраняет ключ и возвращает статус после проверки.
  ///
  /// Провайдер с обязательным ключом не принимает нерабочий ключ: прежнее
  /// значение восстанавливается, наружу уходит [AppFailure].
  Future<LlmProviderStatus> saveProviderApiKey(String providerId, String key);

  /// Удаляет ключ. Адрес и остальные настройки сохраняются.
  Future<void> deleteProviderApiKey(String providerId);

  /// Включает или выключает провайдера.
  Future<void> setProviderEnabled(String providerId, bool enabled);
}

/// Настройки конкретного агента. Локальный адаптер пишет в БД и SecretStore,
/// удалённый — в API профиля.
abstract interface class AgentSettingsApi implements LlmProviderSettingsApi {
  Future<AgentSettingsSnapshot> load();
  Stream<ModelCatalogState> watchCatalog();
  Stream<List<String>> watchPinnedModels();

  Future<void> writeSetting(String key, String? value);
  Future<void> saveStepsDisplay(StepsDisplay value);
  Future<void> savePinnedModels(List<String> ids);
  Future<void> saveDenylist(List<String> patterns);
  Future<void> saveSecurityProfile(SecurityProfile profile);
  Future<void> saveLimits(AppLimits limits);

  Future<void> refreshModels();
  Future<void> rememberModels(List<String> ids);
}
