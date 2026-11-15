/// Провайдер локальных моделей поверх среды выполнения llamadart.
///
/// Провайдер ничего не знает про файлы, скачивание и параметры: он берёт
/// установленные модели из [LocalModelRuntime], отдаёт их в общий каталог и
/// просит среду загрузить файл в память. Включение и выключение провайдера
/// влияет только на каталог и чат: файлами и настройками продолжает управлять
/// среда.
library;

import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llamadart/llamadart_connection.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

/// Адаптер среды выполнения к порту [LlmProvider].
final class LlamadartLlmProvider
    implements LlmProvider, LlmModelRuntimeProvider {
  LlamadartLlmProvider({required this.runtime, required this.readConfig});

  final LocalModelRuntime runtime;

  /// Настройки читаются при каждом вызове: включение действует сразу.
  final Future<LlmProviderConfig> Function() readConfig;

  @override
  List<LlmProviderDescriptor> get providers => const [llamadartDescriptor];

  @override
  Future<bool> get runtimeEnabled async => (await readConfig()).enabled;

  @override
  Future<ProviderRuntimeState> snapshotRuntime() => runtime.snapshotMemory();

  @override
  Stream<ProviderRuntimeState> watchRuntime() => runtime.watchMemory();

  @override
  Future<void> loadRuntimeModel(String localModelId) =>
      runtime.loadIntoMemory(localModelId);

  @override
  Future<void> unloadRuntimeModel(String localModelId) =>
      runtime.unloadFromMemory(localModelId);

  /// Настройки без сети: включённость и число установленных файлов.
  @override
  Future<List<LlmProviderStatus>> configStatuses() async {
    final config = await readConfig();
    final count = await _count();
    return [_statusOf(config, modelCount: count)];
  }

  /// Проверка не ходит в сеть: среда локальная. Ошибка чтения диска
  /// возвращается в [LlmProviderStatus.error], метод не бросает.
  @override
  Future<List<LlmProviderStatus>> statuses() async {
    final config = await readConfig();
    try {
      final models = await runtime.installedModels();
      return [
        _statusOf(
          config,
          modelCount: models.length,
          available: models.isNotEmpty,
          checkedAt: DateTime.now().toUtc(),
        ),
      ];
    } on Object catch (error) {
      return [
        _statusOf(
          config,
          checkedAt: DateTime.now().toUtc(),
          error: error is AppFailure ? error.message : '$error',
        ),
      ];
    }
  }

  @override
  Future<List<LlmModelInfo>> listModels() async {
    final config = await readConfig();
    if (!config.enabled) return const [];
    return [
      for (final model in await runtime.installedModels())
        LlmModelInfo(
          id: model.id,
          name: model.name,
          contextLength: model.settings.contextSize,
          supportsTools: model.settings.supportsTools,
          // С проектором llamadart принимает изображения и аудио; без него
          // модель текстовая.
          inputModalities: model.settings.projectorSource == null
              ? const ['text']
              : ['text', 'image', if (model.settings.projectorAudio) 'audio'],
        ),
    ];
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request) async* {
    final config = await readConfig();
    if (!config.enabled) {
      throw const LlmFailure('llamadart provider is disabled');
    }
    final localId = llamadartDescriptor.localModelId(request.model);
    final model = await runtime.find(localId);
    if (model == null || !model.available) {
      throw LlmFailure(
        'Local model ${request.model} is not installed',
        modelNotFound: true,
      );
    }
    yield* runtime.generate(request, localModelId: localId);
  }

  LlmProviderStatus _statusOf(
    LlmProviderConfig config, {
    int? modelCount,
    bool available = false,
    DateTime? checkedAt,
    String? error,
  }) => LlmProviderStatus(
    id: llamadartProviderId,
    enabled: config.enabled,
    available: available,
    modelCount: modelCount,
    checkedAt: checkedAt,
    error: error,
  );

  Future<int?> _count() async {
    try {
      return (await runtime.installedModels()).length;
    } on Object {
      return null;
    }
  }
}
