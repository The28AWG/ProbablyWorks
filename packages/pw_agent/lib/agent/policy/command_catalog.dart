/// Каталог команд, которые знает разбор `command_shield`.
///
/// Имена уже прогнаны через нормализатор пакета, поэтому `python3` и `/bin/ls`
/// попадают в ту же строку, что и `python` и `ls`. Псевдонимы, которые
/// нормализатор не склеивает, остаются отдельными командами.
library;

import 'package:command_shield/command_shield.dart';
import 'package:pw_agent/agent/policy/agent_command_policy.dart';

/// Снимок базы знаний агента: имя → категория.
class CommandCatalog {
  /// Пустой каталог. Боевой снимок — [load].
  const CommandCatalog(this._categories);

  /// Собирает каталог из той же базы, которой пользуется щит.
  factory CommandCatalog.load() {
    final normalizer = Normalizer.standard();
    final categories = <String, KnowledgeCategory>{};
    for (final entry in agentKnowledgeBase().allKnowledge) {
      final name = normalizer.normalize(entry.executable).toLowerCase();
      if (name.isEmpty) continue;
      categories[name] = entry.category;
    }
    return CommandCatalog(categories);
  }

  /// Единственный снимок на процесс: база знаний не меняется между вызовами.
  static final CommandCatalog instance = CommandCatalog.load();

  final Map<String, KnowledgeCategory> _categories;

  /// Категория нормализованного [executable] или null, если база его не знает.
  KnowledgeCategory? categoryOf(String executable) => _categories[executable];

  /// Имена одной категории, по алфавиту.
  List<String> namesIn(KnowledgeCategory category) => [
    for (final entry in _categories.entries)
      if (entry.value == category) entry.key,
  ]..sort();
}
