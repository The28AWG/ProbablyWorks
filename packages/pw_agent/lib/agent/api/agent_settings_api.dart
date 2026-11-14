import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
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
    required this.apiKeyTail,
    required this.catalog,
    this.llamaCpp = const LlamaCppStatus(),
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
  final String apiKeyTail;
  final ModelCatalogState catalog;

  /// Статус подключения llama.cpp. Не содержит ключа, только маску.
  final LlamaCppStatus llamaCpp;
}

/// Настройки конкретного агента. Локальный адаптер пишет в БД и SecretStore,
/// удалённый — в API профиля.
abstract interface class AgentSettingsApi {
  Future<AgentSettingsSnapshot> load();
  Stream<ModelCatalogState> watchCatalog();
  Stream<List<String>> watchPinnedModels();

  Future<void> writeSetting(String key, String? value);
  Future<void> saveStepsDisplay(StepsDisplay value);
  Future<void> savePinnedModels(List<String> ids);
  Future<void> saveDenylist(List<String> patterns);
  Future<void> saveSecurityProfile(SecurityProfile profile);
  Future<void> saveLimits(AppLimits limits);

  Future<void> saveApiKey(String key);
  Future<void> deleteApiKey();
  Future<LlmKeyInfo?> checkKey();
  Future<void> refreshModels();
  Future<void> rememberModels(List<String> ids);
}

/// Дополнительные настройки llama.cpp.
///
/// Отдельный интерфейс, чтобы не расширять [AgentSettingsApi] и не ломать
/// реализации, которым llama.cpp не нужен. Адаптеры, поддерживающие
/// настройки, реализуют оба интерфейса.
abstract interface class LlamaCppSettingsApi {
  Future<void> saveLlamaCppBaseUrl(String baseUrl);
  Future<void> saveLlamaCppApiKey(String key);
  Future<void> deleteLlamaCppApiKey();
  Future<void> setLlamaCppEnabled(bool enabled);
  Future<LlamaCppStatus?> checkLlamaCpp();
}
