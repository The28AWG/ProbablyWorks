import 'package:pw_agent/agent/tools/tool_types.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Источник инструментов, которые не входят в встроенный каталог.
///
/// Policy, подтверждения и запись ToolRun остаются в [ToolExecutor]: источник
/// получает уже разрешённый вызов и не может обойти общий путь.
abstract base class ToolSource {
  /// Стабильный идентификатор источника. По нему источник можно заменить или снять.
  String get id;

  /// Описания инструментов для модели. Имена должны быть уникальны.
  List<LlmToolSpec> get specs;

  /// Меняет ли источник файлы или состояние Host. Для неизвестных внешних
  /// инструментов считаем, что меняет: тогда rollback хода запрещён.
  bool get mutatesHost => true;

  /// Выполняет вызов. Policy и approve к этому моменту уже пройдены.
  Future<ToolResult> call(
    LlmToolCall call,
    Map<String, dynamic> arguments,
    ToolContext context,
  );

  /// Короткая подпись для карточки подтверждения и журнала.
  String summaryFor(LlmToolCall call, Map<String, dynamic> arguments) =>
      call.name;

  /// Причина, которую увидит пользователь в карточке подтверждения.
  String reasonFor(LlmToolCall call) => 'external tool';
}
