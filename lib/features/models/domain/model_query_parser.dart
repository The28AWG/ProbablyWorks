import 'package:probably_works/core/util/at_query.dart';
import 'package:probably_works/features/models/domain/model_list_query.dart';

/// Почему фильтр `@provider:` не применён.
enum ModelProviderProblemKind {
  /// Такого провайдера нет.
  unknown,

  /// С введённым префиксом начинается несколько провайдеров.
  ambiguous,
}

/// Неприменённый фильтр провайдера: подсказка под полем поиска.
class ModelProviderProblem {
  const ModelProviderProblem({
    required this.value,
    required this.kind,
    this.candidates = const [],
  });

  /// Что ввёл пользователь (без кавычек).
  final String value;
  final ModelProviderProblemKind kind;

  /// Подходящие провайдеры при [ModelProviderProblemKind.ambiguous].
  final List<String> candidates;
}

/// Результат разбора строки поиска моделей.
class ModelQueryParse {
  const ModelQueryParse({required this.query, this.providerProblem});

  final ModelListQuery query;
  final ModelProviderProblem? providerProblem;
}

/// Разбор строки поиска моделей: свободный текст и фильтры `@...`.
///
/// Синтаксис общий с палитрой команд: `@` в начале слова, значение в кавычках,
/// алиасы на русском. Неизвестный фильтр остаётся текстом запроса, поэтому
/// пользователь не теряет введённое. Исключение — известный фильтр с неверным
/// значением: он не применяется и возвращается в [ModelQueryParse.providerProblem],
/// иначе список просто оказался бы пустым без причины.
abstract final class ModelQueryParser {
  const ModelQueryParser._();

  static const _aliases = <String, String>{
    'provider': 'provider',
    'провайдер': 'provider',
    'free': 'free',
    'бесплатные': 'free',
    'бесплатно': 'free',
    'tools': 'tools',
    'инструменты': 'tools',
  };

  /// Канонические фильтры в порядке подсказок.
  static const filterNames = ['provider', 'free', 'tools'];

  /// Токен выбора фильтра: `@provider:` открывает список провайдеров.
  static String tokenOf(String canonical) =>
      canonical == 'provider' ? '@provider:' : '@$canonical';

  static String? canonicalFilter(String name) => _aliases[name];

  /// Алиасы канонического фильтра: подсказка показывает, что `@б` — это «бесплатные».
  static List<String> aliasesOf(String canonical) => [
    for (final entry in _aliases.entries)
      if (entry.value == canonical) entry.key,
  ];

  /// Начинается ли хотя бы один алиас с [prefix]: нужно автодополнению.
  static bool isAliasPrefix(String prefix) {
    if (prefix.isEmpty) return true;
    for (final alias in _aliases.keys) {
      if (alias.startsWith(prefix)) return true;
    }
    return false;
  }

  static ModelQueryParse parse(
    String raw, {
    List<String> providers = const [],
  }) {
    final text = StringBuffer();
    var freeOnly = false;
    var toolsOnly = false;
    var provider = '';
    ModelProviderProblem? problem;
    // Всё, что не распознано как фильтр, возвращаем в текст запроса.
    var cursor = 0;
    for (final token in AtQuery.tokens(raw)) {
      text.write(AtQuery.textOf(raw, cursor, token.start));
      cursor = token.end;
      final canonical = _aliases[token.name];
      if (canonical == null) {
        _keepAsText(text, token.raw);
        continue;
      }
      switch (canonical) {
        case 'free':
          if (token.hasValue) {
            _keepAsText(text, token.raw);
            break;
          }
          freeOnly = true;
        case 'tools':
          if (token.hasValue) {
            _keepAsText(text, token.raw);
            break;
          }
          toolsOnly = true;
        case 'provider':
          if (token.value.isEmpty) {
            _keepAsText(text, token.raw);
            break;
          }
          final match = matchProvider(token.value, providers);
          // Последний фильтр провайдера решает: он виден в строке последним.
          provider = match.label ?? '';
          problem = switch (match) {
            ProviderMatchFound() => null,
            ProviderMatchAmbiguous(:final candidates) => ModelProviderProblem(
              value: token.value,
              kind: ModelProviderProblemKind.ambiguous,
              candidates: candidates,
            ),
            ProviderMatchNotFound() => ModelProviderProblem(
              value: token.value,
              kind: ModelProviderProblemKind.unknown,
            ),
          };
      }
    }
    text.write(AtQuery.textOf(raw, cursor, raw.length));
    return ModelQueryParse(
      query: ModelListQuery(
        search: _squash(text.toString()),
        freeOnly: freeOnly,
        toolsOnly: toolsOnly,
        provider: provider,
      ),
      providerProblem: problem,
    );
  }

  static void _keepAsText(StringBuffer text, String raw) {
    text
      ..write(raw)
      ..write(' ');
  }

  static String _squash(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();
}
