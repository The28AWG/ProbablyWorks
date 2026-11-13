import 'package:probably_works/features/palette/domain/command_search.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';

/// Команда, найденная поиском, с оценкой и путём в дереве.
class CommandMatch {
  const CommandMatch({
    required this.command,
    required this.score,
    required this.path,
  });

  final PaletteCommand command;
  final double score;
  final String path;
}

/// Дерево команд палитры. Команды с `parentId` вкладываются в группы.
///
/// В поиске участвуют только листья: группы нужны для навигации пустого
/// запроса и для пути в результате.
class CommandRegistry {
  CommandRegistry(Iterable<PaletteCommand> commands) {
    for (final command in commands) {
      if (_commands.containsKey(command.id)) {
        throw ArgumentError('duplicate command id: ${command.id}');
      }
      _commands[command.id] = command;
    }
    for (final command in _commands.values) {
      final parentId = command.parentId;
      if (parentId == null) continue;
      final parent = _commands[parentId];
      if (parent == null) {
        throw ArgumentError(
          'command ${command.id} references missing parent $parentId',
        );
      }
      if (!parent.isGroup) {
        throw ArgumentError('parent $parentId is not a group');
      }
    }
    for (final command in _commands.values) {
      if (_isCyclic(command)) {
        throw ArgumentError('command hierarchy has a cycle at ${command.id}');
      }
    }
  }

  final _commands = <String, PaletteCommand>{};

  PaletteCommand? byId(String id) => _commands[id];

  Iterable<PaletteCommand> get all => _commands.values;

  /// Команды верхнего уровня или дети группы.
  List<PaletteCommand> childrenOf(String? parentId, String language) {
    final result = [
      for (final command in _commands.values)
        if (command.parentId == parentId && command.enabled) command,
    ];
    return result..sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      if (byOrder != 0) return byOrder;
      return a.titles
          .forLanguage(language)
          .toLowerCase()
          .compareTo(b.titles.forLanguage(language).toLowerCase());
    });
  }

  /// Путь до команды, включая её саму: «Навигация → Чаты».
  String pathOf(PaletteCommand command, String language) {
    final parts = <String>[];
    PaletteCommand? current = command;
    var depth = 0;
    while (current != null && depth++ < 32) {
      parts.add(current.titles.forLanguage(language));
      final parentId = current.parentId;
      current = parentId == null ? null : _commands[parentId];
    }
    return parts.reversed.join(' → ');
  }

  /// Поиск по листьям. Все термы должны найтись хотя бы в одном поле.
  List<CommandMatch> search(String query, String language) {
    final terms = normalizeSearchText(query)
        .split(' ')
        .where((t) => t.isNotEmpty);
    if (terms.isEmpty) return const [];
    final matches = <CommandMatch>[];
    for (final command in _commands.values) {
      if (command.isGroup || !command.enabled) continue;
      final score = _score(command, terms.toList(), language);
      if (score <= 0) continue;
      matches.add(
        CommandMatch(
          command: command,
          score: score,
          path: pathOf(command, language),
        ),
      );
    }
    matches.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.command.titles
          .forLanguage(language)
          .toLowerCase()
          .compareTo(b.command.titles.forLanguage(language).toLowerCase());
    });
    return matches;
  }

  double _score(PaletteCommand command, List<String> terms, String language) {
    final path = pathOf(command, language);
    final fields = <(String, double)>[
      (command.titles.forLanguage(language), 1),
      (command.titles.forLanguage(language == 'ru' ? 'en' : 'ru'), 0.85),
      (command.keywords.forLanguage(language), 0.7),
      (command.keywords.forLanguage(language == 'ru' ? 'en' : 'ru'), 0.6),
      (path, 0.45),
    ];
    var sum = 0.0;
    for (final term in terms) {
      var best = 0.0;
      for (final (text, weight) in fields) {
        final value = scoreSearchText(text, term) * weight;
        if (value > best) best = value;
      }
      if (best <= 0) return 0;
      sum += best;
    }
    final average = sum / terms.length;
    final exact =
        normalizeSearchText(command.titles.forLanguage(language)) ==
        normalizeSearchText(terms.join(' '));
    return exact ? 1 : average;
  }

  bool _isCyclic(PaletteCommand command) {
    final seen = <String>{};
    PaletteCommand? current = command;
    while (current != null) {
      if (!seen.add(current.id)) return true;
      final parentId = current.parentId;
      current = parentId == null ? null : _commands[parentId];
    }
    return false;
  }
}
