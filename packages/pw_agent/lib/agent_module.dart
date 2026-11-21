import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/chat_run_stopper.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/turn/turn_changeset_store.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/local_model_download_repository.dart';
import 'package:pw_agent/core/data/local_model_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_llm_provider.dart';
import 'package:pw_agent/providers/ai/llamadart/llamadart_connection.dart';
import 'package:pw_agent/providers/ai/llamadart/llamadart_llm_provider.dart';
import 'package:pw_agent/providers/ai/llamadart/local_models_service.dart';
import 'package:pw_agent/providers/ai/llamadart/local_storage.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/llm_provider_registry.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_runtime_service.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';
import 'package:pw_agent/providers/ai/provider_settings_store.dart';
import 'package:pw_agent/src/agent/loop/agent_hub.dart';

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

  /// Среда выполнения локальных моделей. Живёт независимо от провайдера:
  /// файлами и параметрами можно управлять при выключенном провайдере.
  ///
  /// [LocalModelStorage] регистрируется снаружи: приложение на мобильных
  /// использует платформенный загрузчик, демон и desktop — Dart-менеджер.
  @singleton
  LocalModelsService localModelsService(
    AppPaths paths,
    LocalModelRepository repository,
    LocalModelDownloadRepository downloadJobs,
    SettingsRepository settings,
    LocalModelStorage storage,
  ) => LocalModelsService(paths, repository, downloadJobs, settings, storage);

  /// Среда выполнения под интерфейсом: API настроек зависит от порта,
  /// а провайдер — от конкретного сервиса.
  @singleton
  LocalModelsSource localModelsSource(LocalModelsService service) => service;

  /// Провайдер локальных моделей. Настройки читаются при каждом запросе.
  @singleton
  LlamadartLlmProvider llamadartLlmProvider(
    LocalModelsService runtime,
    LlmProviderSettingsStore settings,
  ) => LlamadartLlmProvider(
    runtime: runtime,
    readConfig: () => settings.read(llamadartDescriptor),
  );

  /// Единый провайдер для агента и каталога.
  ///
  /// Новый провайдер добавляется в этот список: остальные слои работают
  /// через дескрипторы и не знают его имени.
  @singleton
  LlmProviderRegistry llmProviderRegistry(
    OpenRouterLlmProvider openRouter,
    LlamaCppLlmProvider llamaCpp,
    LlamadartLlmProvider llamadart,
  ) => LlmProviderRegistry([openRouter, llamaCpp, llamadart]);

  /// Алиас для потребителей, которым нужен только порт [LlmProvider].
  @singleton
  LlmProvider llmProvider(LlmProviderRegistry registry) => registry;

  /// Наблюдение за загрузкой моделей. Провайдеры без runtime просто не
  /// попадают в реестр возможностей.
  @singleton
  ModelRuntimeService modelRuntimeService(LlmProviderRegistry registry) =>
      ModelRuntimeService(registry);

  /// Остановка хода для очистки истории: реализация живёт в [AgentHub].
  @lazySingleton
  ChatRunStopper chatRunStopper(AgentHub hub) => hub;
}
