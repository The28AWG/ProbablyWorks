import 'package:pw_agent/agent/tools/self_tool_catalog.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/agent/tools/tool_source.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Общий список инструментов: встроенные плюс зарегистрированные источники.
///
/// Реестр не выполняет вызовы. Он только собирает описания для модели и говорит
/// [ToolExecutor], какому источнику принадлежит имя.
final class ToolRegistry {
  final _sources = <String, ToolSource>{};
  final _owners = <String, ToolSource>{};

  late final Set<String> _builtinNames = {
    for (final spec in [...ToolCatalog.specs, ...SelfToolCatalog.specs])
      spec.name,
  };

  /// Описания для LlmRequest. Порядок стабилен: встроенные, затем источники
  /// в порядке регистрации.
  List<LlmToolSpec> get specs => List.unmodifiable([
    ...ToolCatalog.specs,
    ...SelfToolCatalog.specs,
    for (final source in _sources.values) ...source.specs,
  ]);

  /// Источник, которому принадлежит имя, или null для встроенного инструмента.
  ToolSource? sourceFor(String toolName) => _owners[toolName];

  /// Регистрирует источник. Дубликаты id и имён — ошибка разработчика.
  void register(ToolSource source) {
    if (source.id.isEmpty) {
      throw ArgumentError.value(source.id, 'source.id', 'must not be empty');
    }
    if (_sources.containsKey(source.id)) {
      throw ArgumentError.value(source.id, 'source.id', 'already registered');
    }
    final seen = <String>{};
    for (final spec in source.specs) {
      if (!seen.add(spec.name)) {
        throw StateError('${source.id} declares duplicate tool ${spec.name}');
      }
      if (_builtinNames.contains(spec.name) || _owners.containsKey(spec.name)) {
        throw StateError(
          'tool ${spec.name} from ${source.id} conflicts with an existing tool',
        );
      }
    }
    _sources[source.id] = source;
    for (final spec in source.specs) {
      _owners[spec.name] = source;
    }
  }

  /// Снимает источник и все его имена. Повторный вызов с тем же id безопасен.
  void unregister(String sourceId) {
    final source = _sources.remove(sourceId);
    if (source == null) return;
    for (final spec in source.specs) {
      if (identical(_owners[spec.name], source)) {
        _owners.remove(spec.name);
      }
    }
  }
}
