/// Провайдер, который объединяет OpenRouter и llama.cpp.
///
/// Модели llama.cpp получают префикс [llamaCppModelPrefix], поэтому id
/// OpenRouter не меняются и сохранённые чаты продолжают работать.
/// Ошибка одного провайдера не скрывает модели другого: если хоть один
/// вернул список, каталог обновляется, а ошибка пишется в лог.
library;

import 'package:logging/logging.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_llm_provider.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';

/// Маршрутизирует запросы по префиксу id модели и собирает общий каталог.
class MultiLlmProvider implements LlmProvider, LlamaCppStatusProvider {
  MultiLlmProvider({required this.openRouter, required this.llamaCpp});

  final OpenRouterLlmProvider openRouter;
  final LlamaCppLlmProvider llamaCpp;

  static final _log = Logger('MultiLlmProvider');

  @override
  Future<bool> get isEnabled => llamaCpp.isEnabled;

  @override
  Future<bool> get isAvailable => llamaCpp.isAvailable;

  @override
  Future<LlamaCppStatus> checkHealth() => llamaCpp.checkHealth();

  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    if (isLlamaCppModel(request.model)) return llamaCpp.stream(request);
    return openRouter.stream(request);
  }

  @override
  Future<LlmKeyInfo> checkKey() async {
    if (await openRouter.hasKey) return openRouter.checkKey();
    if (await llamaCpp.isEnabled) return llamaCpp.checkKey();
    throw const LlmFailure('No AI provider is configured');
  }

  @override
  Future<List<LlmModelInfo>> listModels() async {
    final models = <LlmModelInfo>[];
    final errors = <String>[];

    if (await openRouter.hasKey) {
      try {
        models.addAll(await openRouter.listModels());
      } on Object catch (error) {
        _log.warning('OpenRouter model list failed', error);
        errors.add(error is LlmFailure ? error.message : '$error');
      }
    }

    if (await llamaCpp.isEnabled) {
      try {
        models.addAll([
          for (final model in await llamaCpp.listModels())
            LlmModelInfo(
              id: '$llamaCppModelPrefix${model.id}',
              name: model.name,
              contextLength: model.contextLength,
              supportsTools: model.supportsTools,
              created: model.created,
              inputModalities: model.inputModalities,
            ),
        ]);
      } on Object catch (error) {
        _log.warning('llama.cpp model list failed', error);
        errors.add(error is LlmFailure ? error.message : '$error');
      }
    }

    if (models.isEmpty && errors.isNotEmpty) {
      throw LlmFailure(errors.join('; '));
    }
    return models;
  }
}
