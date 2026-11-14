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
import 'package:pw_agent/providers/ai/multi_llm_provider.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';

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

  /// Ключ OpenRouter читается при каждом запросе: смена ключа в Settings действует сразу.
  @singleton
  OpenRouterLlmProvider openRouterLlmProvider(SecretStore secrets) =>
      OpenRouterLlmProvider(apiKey: () => secrets.read(openRouterKeyName));

  /// Настройки llama.cpp читаются при каждом запросе.
  @singleton
  LlamaCppSettingsReader llamaCppSettingsReader(
    SettingsRepository settings,
    SecretStore secrets,
  ) => LlamaCppSettingsReader(settings, secrets);

  @singleton
  LlamaCppLlmProvider llamaCppLlmProvider(LlamaCppSettingsReader settings) =>
      LlamaCppLlmProvider(settings: settings);

  /// Агент видит единый провайдер: он маршрутизирует по префиксу id модели.
  @singleton
  LlmProvider llmProvider(
    OpenRouterLlmProvider openRouter,
    LlamaCppLlmProvider llamaCpp,
  ) => MultiLlmProvider(openRouter: openRouter, llamaCpp: llamaCpp);
}
