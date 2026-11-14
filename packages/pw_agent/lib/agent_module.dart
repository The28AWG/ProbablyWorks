import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/turn/turn_changeset_store.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_llm_provider.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/llm_provider_registry.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';
import 'package:pw_agent/providers/ai/provider_settings_store.dart';

/// Ресурсы агента, которым нужны каталоги и секреты.
///
/// [AppPaths] и [SecretStore] регистрируются снаружи: клиентом или демоном.
@module
abstract class AgentCoreModule {
  @preResolve
  Future<AppDatabase> database(AppPaths paths) async =>
      openAppDatabase(paths.support);

  @singleton
  ExecLogStore execLogStore(AppPaths paths) => ExecLogStore(paths.root);

  @singleton
  TurnChangesetStore turnChangesetStore(AppPaths paths) =>
      TurnChangesetStore(paths.root);

  /// Общие ключи настроек и секретов всех провайдеров.
  @singleton
  LlmProviderSettingsStore llmProviderSettingsStore(
    SettingsRepository settings,
    SecretStore secrets,
  ) => LlmProviderSettingsStore(settings, secrets);

  /// Ключ OpenRouter читается при каждом запросе: смена ключа в Settings действует сразу.
  @singleton
  OpenRouterLlmProvider openRouterLlmProvider(
    LlmProviderSettingsStore settings,
  ) => OpenRouterLlmProvider(
    readConfig: () => settings.read(openRouterDescriptor),
  );

  /// Настройки llama.cpp читаются при каждом запросе.
  @singleton
  LlamaCppLlmProvider llamaCppLlmProvider(LlmProviderSettingsStore settings) =>
      LlamaCppLlmProvider(readConfig: () => settings.read(llamaCppDescriptor));

  /// Единый провайдер для агента и каталога.
  ///
  /// Новый провайдер добавляется в этот список: остальные слои работают
  /// через дескрипторы и не знают его имени.
  @singleton
  LlmProviderRegistry llmProviderRegistry(
    OpenRouterLlmProvider openRouter,
    LlamaCppLlmProvider llamaCpp,
  ) => LlmProviderRegistry([openRouter, llamaCpp]);

  /// Алиас для потребителей, которым нужен только порт [LlmProvider].
  @singleton
  LlmProvider llmProvider(LlmProviderRegistry registry) => registry;
}
