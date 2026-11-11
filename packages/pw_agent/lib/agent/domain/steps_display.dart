import 'package:equatable/equatable.dart';

/// Какие рассуждения модели показывать в журнале шагов.
enum ThoughtsVisibility {
  /// Только рассуждение, которое стримится прямо сейчас.
  current,

  /// Все рассуждения ответа, но свёрнутые: журнал и строки раскрывает пользователь («Скрывать»).
  all,

  /// Все рассуждения ответа, раскрытые целиком: журнал и каждая строка открыты («Все»).
  expanded,
}

/// Какие вызовы инструментов показывать в журнале шагов.
enum ToolsVisibility {
  /// Только вызовы, которые выполняются или ждут ответа.
  active,

  /// Все вызовы ответа, но свёрнутые: журнал и строки раскрывает пользователь («Скрывать»).
  all,

  /// Все вызовы ответа, раскрытые целиком: журнал и вывод каждой команды открыты («Все»).
  expanded,
}

/// Поведение журнала шагов по умолчанию. Настраивается в Settings и применяется к ленте чата.
final class StepsDisplay extends Equatable {
  const StepsDisplay({
    this.group = true,
    this.expandWhileActive = true,
    this.thoughts = ThoughtsVisibility.all,
    this.tools = ToolsVisibility.all,
  });

  static const defaults = StepsDisplay();

  /// Группировать шаги одного ответа в один журнал. Выключено: каждый шаг идёт отдельной строкой.
  final bool group;

  /// Раскрывать группу, пока её шаги выполняются или рассуждают. Выключено: группа остаётся свёрнутой,
  /// её раскрывает пользователь. Ошибки и ожидание ответа раскрывают группу в любом случае.
  final bool expandWhileActive;

  final ThoughtsVisibility thoughts;
  final ToolsVisibility tools;

  StepsDisplay copyWith({
    bool? group,
    bool? expandWhileActive,
    ThoughtsVisibility? thoughts,
    ToolsVisibility? tools,
  }) => StepsDisplay(
    group: group ?? this.group,
    expandWhileActive: expandWhileActive ?? this.expandWhileActive,
    thoughts: thoughts ?? this.thoughts,
    tools: tools ?? this.tools,
  );

  @override
  List<Object?> get props => [group, expandWhileActive, thoughts, tools];
}
