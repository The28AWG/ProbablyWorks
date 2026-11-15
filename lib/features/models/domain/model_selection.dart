import 'package:pw_agent/providers/ai/llm_port.dart';

/// Результат выбора модели: сама модель и уровень рассуждений.
///
/// Используется диалогом выбора модели и полями настроек, чтобы не терять
/// уровень при смене модели.
class ModelSelection {
  const ModelSelection({required this.model, required this.reasoning});

  final LlmModelInfo model;
  final ReasoningPreference reasoning;
}
