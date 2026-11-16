import 'dart:math';

import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/providers/ai/llm_provider_meta.dart';

/// Эффективный потолок шагов за ход для модели.
///
/// [AppLimits.maxAgentSteps] — аварийный потолок для любого провайдера,
/// ноль означает «без ограничения». Провайдер с
/// [ProviderStepPolicy.economical] дополнительно ограничен
/// [AppLimits.economicalMaxAgentSteps]: его вызовы нельзя считать
/// бесконечными, даже если бюджеты хода отключены.
///
/// Возвращает null, когда шаги не ограничены.
int? effectiveStepCap({
  required AppLimits limits,
  required LlmProviderDescriptor? provider,
}) {
  final economical = provider?.stepPolicy == ProviderStepPolicy.economical;
  final caps = <int>[
    if (limits.maxAgentSteps > 0) limits.maxAgentSteps,
    if (economical) limits.economicalMaxAgentSteps,
  ];
  return caps.isEmpty ? null : caps.reduce(min);
}
