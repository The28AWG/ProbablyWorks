import 'package:equatable/equatable.dart';

/// Какие рассуждения модели показывать в журнале шагов.
enum ThoughtsVisibility {
  /// Только рассуждение, которое стримится прямо сейчас.
  current,

  /// Все рассуждения ответа.
  all,
}

/// Какие вызовы инструментов показывать в журнале шагов.
enum ToolsVisibility {
  /// Только вызовы, которые выполняются или ждут ответа.
  active,

  /// Все вызовы ответа.
  all,
}

/// Поведение журнала шагов по умолчанию. Настраивается в Settings и применяется к ленте чата.
final class StepsDisplay extends Equatable {
  const StepsDisplay({
    this.group = true,
    this.thoughts = ThoughtsVisibility.all,
    this.tools = ToolsVisibility.all,
  });

  static const defaults = StepsDisplay();

  /// Группировать шаги одного ответа в один журнал. Выключено: каждый шаг идёт отдельной строкой.
  final bool group;
  final ThoughtsVisibility thoughts;
  final ToolsVisibility tools;

  StepsDisplay copyWith({
    bool? group,
    ThoughtsVisibility? thoughts,
    ToolsVisibility? tools,
  }) => StepsDisplay(
    group: group ?? this.group,
    thoughts: thoughts ?? this.thoughts,
    tools: tools ?? this.tools,
  );

  @override
  List<Object?> get props => [group, thoughts, tools];
}
