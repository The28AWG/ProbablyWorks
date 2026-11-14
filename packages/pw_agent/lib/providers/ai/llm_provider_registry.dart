/// Реестр LLM-провайдеров: единая точка маршрутизации и каталога.
///
/// Новый провайдер добавляется одной регистрацией в [AgentCoreModule].
/// Реестр сам добавляет префикс к id его моделей, маршрутизирует запросы,
/// собирает статусы и решает, настроен ли хоть один провайдер.
library;

import 'package:logging/logging.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Объединяет адаптеры провайдеров в один [LlmProvider].
class LlmProviderRegistry implements LlmProvider {
  LlmProviderRegistry(this._adapters);

  final List<LlmProvider> _adapters;
  static final _log = Logger('LlmProviderRegistry');

  /// Все дескрипторы зарегистрированных провайдеров в порядке регистрации.
  @override
  List<LlmProviderDescriptor> get providers => [
    for (final adapter in _adapters) ...adapter.providers,
  ];

  /// Дескриптор по id. Null — провайдер не зарегистрирован.
  LlmProviderDescriptor? descriptorById(String id) {
    for (final descriptor in providers) {
      if (descriptor.id == id) return descriptor;
    }
    return null;
  }

  /// Адаптер по id провайдера. Null — провайдер не зарегистрирован.
  LlmProvider? adapterById(String id) {
    for (final adapter in _adapters) {
      for (final descriptor in adapter.providers) {
        if (descriptor.id == id) return adapter;
      }
    }
    return null;
  }

  /// Адаптер, которому принадлежит id модели.
  ///
  /// Сначала проверяются провайдеры с непустым префиксом, затем провайдер
  /// без префикса. Так модели `llamacpp:` не уходят в OpenRouter.
  LlmProvider? adapterForModel(String modelId) {
    for (final adapter in _adapters) {
      for (final descriptor in adapter.providers) {
        if (descriptor.modelPrefix.isNotEmpty &&
            descriptor.ownsModel(modelId)) {
          return adapter;
        }
      }
    }
    for (final adapter in _adapters) {
      for (final descriptor in adapter.providers) {
        if (descriptor.modelPrefix.isEmpty) return adapter;
      }
    }
    return null;
  }

  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    final adapter = adapterForModel(request.model);
    if (adapter == null) {
      throw LlmFailure('No AI provider serves model ${request.model}');
    }
    return adapter.stream(request);
  }

  /// Собирает модели всех настроенных провайдеров, добавляя префиксы.
  ///
  /// Ошибка одного провайдера не скрывает модели другого. Если ни один не
  /// ответил, наружу уходит общая [LlmFailure]: пустой список нельзя
  /// выдавать за успешную загрузку.
  @override
  Future<List<LlmModelInfo>> listModels() async {
    final models = <LlmModelInfo>[];
    final errors = <String>[];
    var configured = 0;

    for (final adapter in _adapters) {
      final descriptor = adapter.providers.isEmpty
          ? null
          : adapter.providers.first;
      if (descriptor == null) continue;
      if (!await _isConfigured(adapter)) continue;
      configured++;
      try {
        final listed = await adapter.listModels();
        models.addAll([
          for (final model in listed)
            model.copyWith(id: descriptor.globalModelId(model.id)),
        ]);
      } on Object catch (error) {
        _log.warning('${descriptor.id} model list failed', error);
        errors.add(error is LlmFailure ? error.message : '$error');
      }
    }

    if (configured == 0) {
      throw const LlmFailure('No AI provider is configured');
    }
    if (models.isEmpty && errors.isNotEmpty) {
      throw LlmFailure(errors.join('; '));
    }
    return models;
  }

  /// Настройки всех провайдеров без сети.
  @override
  Future<List<LlmProviderStatus>> configStatuses() async {
    final result = <LlmProviderStatus>[];
    for (final adapter in _adapters) {
      try {
        result.addAll(await adapter.configStatuses());
      } on Object catch (error, stack) {
        _log.warning('cannot read provider config', error, stack);
      }
    }
    return result;
  }

  /// Проверка всех провайдеров. Ошибка одного не мешает остальным.
  @override
  Future<List<LlmProviderStatus>> statuses() async {
    final result = <LlmProviderStatus>[];
    for (final adapter in _adapters) {
      try {
        result.addAll(await adapter.statuses());
      } on Object catch (error, stack) {
        _log.warning('provider status check failed', error, stack);
        for (final descriptor in adapter.providers) {
          result.add(
            LlmProviderStatus(
              id: descriptor.id,
              error: '$error',
              checkedAt: DateTime.now(),
            ),
          );
        }
      }
    }
    return result;
  }

  /// Настроен ли провайдер: включён и имеет обязательный ключ.
  /// Сеть не трогает, поэтому подходит для guard и автообновления.
  Future<bool> get hasUsableProvider async {
    for (final adapter in _adapters) {
      if (await _isConfigured(adapter)) return true;
    }
    return false;
  }

  Future<bool> _isConfigured(LlmProvider adapter) async {
    final statuses = await adapter.configStatuses();
    for (final descriptor in adapter.providers) {
      final status = _statusOf(statuses, descriptor.id);
      if (status == null) continue;
      if (!status.enabled) continue;
      if (descriptor.requiresApiKey && !status.apiKeySet) continue;
      return true;
    }
    return false;
  }

  static LlmProviderStatus? _statusOf(
    List<LlmProviderStatus> statuses,
    String id,
  ) {
    for (final status in statuses) {
      if (status.id == id) return status;
    }
    return null;
  }
}
