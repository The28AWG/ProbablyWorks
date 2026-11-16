import 'package:probably_works/core/util/search_text.dart';
import 'package:probably_works/features/models/domain/model_id.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Порядок списка в диалоге выбора моделей. [provider] — группы по провайдеру, остальные — плоский список.
enum ModelSort { provider, name, context, price, newest }

/// Подпись провайдера модели: для провайдера с префиксом — его label,
/// иначе часть id до `/` (upstream-провайдер OpenRouter).
String providerOf(
  String id, {
  List<LlmProviderDescriptor> providers = const [],
}) {
  final descriptor = providerDescriptorOf(id, providers);
  if (descriptor != null && descriptor.modelPrefix.isNotEmpty) {
    return descriptor.label;
  }
  final slash = id.indexOf('/');
  return slash <= 0 ? id : charPrefix(id, slash);
}

/// Суммарная цена за токен (вход + выход). Null, если цена неизвестна.
double? totalPriceOf(LlmModelInfo model) {
  final input = double.tryParse(model.promptPrice ?? '');
  final output = double.tryParse(model.completionPrice ?? '');
  if (input == null || output == null) return null;
  return input + output;
}

/// Бесплатная модель: известна цена, и она нулевая.
bool isFreeModel(LlmModelInfo model) => totalPriceOf(model) == 0;

/// Провайдеры доступных моделей, по алфавиту.
List<String> providersOf(
  List<LlmModelInfo> models, {
  List<LlmProviderDescriptor> providers = const [],
}) {
  final labels = <String>{
    for (final model in models) providerOf(model.id, providers: providers),
  };
  return labels.toList()..sort(_compareNames);
}

/// Сколько моделей у каждого провайдера. Нужно подсказкам `@provider:`.
Map<String, int> providerCountsOf(
  List<LlmModelInfo> models, {
  List<LlmProviderDescriptor> providers = const [],
}) {
  final counts = <String, int>{};
  for (final model in models) {
    final label = providerOf(model.id, providers: providers);
    counts[label] = (counts[label] ?? 0) + 1;
  }
  return counts;
}

/// Результат сопоставления значения фильтра `@provider:` с провайдером каталога.
sealed class ProviderMatch {
  const ProviderMatch();

  /// Провайдер найден: точное совпадение подписи или единственный префикс.
  const factory ProviderMatch.found(String label) = ProviderMatchFound;

  /// Ни один провайдер не начинается с введённого значения.
  const factory ProviderMatch.notFound() = ProviderMatchNotFound;

  /// С префиксом начинается несколько провайдеров: фильтр не применяется,
  /// иначе `@provider:llama` смешал бы `llama.cpp` и `llamadart`.
  const factory ProviderMatch.ambiguous(List<String> candidates) =
      ProviderMatchAmbiguous;

  /// Подпись провайдера. Null — фильтр не применён.
  String? get label;
}

/// Найденный провайдер.
final class ProviderMatchFound extends ProviderMatch {
  const ProviderMatchFound(this.label);

  @override
  final String label;
}

/// Значение не совпало ни с одним провайдером.
final class ProviderMatchNotFound extends ProviderMatch {
  const ProviderMatchNotFound();

  @override
  String? get label => null;
}

/// Значение подходит к нескольким провайдерам.
final class ProviderMatchAmbiguous extends ProviderMatch {
  const ProviderMatchAmbiguous(this.candidates);

  /// Провайдеры, подходящие под префикс, по алфавиту.
  final List<String> candidates;

  @override
  String? get label => null;
}

/// Сопоставляет значение `@provider:` с подписью провайдера.
///
/// Сначала ищется точное совпадение без учёта регистра и пунктуации
/// (`llama.cpp` = `llama cpp`), затем единственный провайдер, подпись которого
/// начинается с введённого текста. Несколько кандидатов — неоднозначность:
/// фильтр не применяется, а интерфейс показывает варианты.
ProviderMatch matchProvider(String value, List<String> providers) {
  final needle = normalizeSearchText(value);
  if (needle.isEmpty) return const ProviderMatchNotFound();
  for (final provider in providers) {
    if (normalizeSearchText(provider) == needle) {
      return ProviderMatch.found(provider);
    }
  }
  final candidates = [
    for (final provider in providers)
      if (normalizeSearchText(provider).startsWith(needle)) provider,
  ]..sort(_compareNames);
  return switch (candidates) {
    [] => const ProviderMatchNotFound(),
    [final only] => ProviderMatch.found(only),
    _ => ProviderMatchAmbiguous(candidates),
  };
}

/// Фильтры и сортировка диалога выбора. Пустой [provider] — все провайдеры.
class ModelListQuery {
  const ModelListQuery({
    this.search = '',
    this.toolsOnly = true,
    this.freeOnly = false,
    this.provider = '',
    this.sort = ModelSort.provider,
  });

  /// Свободный текст без `@`-фильтров.
  final String search;
  final bool toolsOnly;
  final bool freeOnly;

  /// Подпись провайдера или пустая строка.
  final String provider;
  final ModelSort sort;

  /// Есть ли что-то кроме сортировки: нужно счётчику и кнопке сброса.
  bool get hasFilters =>
      search.trim().isNotEmpty || freeOnly || toolsOnly || provider.isNotEmpty;

  ModelListQuery copyWith({
    String? search,
    bool? toolsOnly,
    bool? freeOnly,
    String? provider,
    ModelSort? sort,
  }) => ModelListQuery(
    search: search ?? this.search,
    toolsOnly: toolsOnly ?? this.toolsOnly,
    freeOnly: freeOnly ?? this.freeOnly,
    provider: provider ?? this.provider,
    sort: sort ?? this.sort,
  );

  /// Структурные фильтры: инструменты, цена и провайдер.
  ///
  /// Текст в запрос не входит: он оценивается в [applyModelQuery], чтобы
  /// найти не только подстроку, но и близкие по смыслу записи.
  bool accepts(
    LlmModelInfo model, {
    List<LlmProviderDescriptor> providers = const [],
  }) {
    if (toolsOnly && !model.supportsTools) return false;
    if (freeOnly && !isFreeModel(model)) return false;
    if (provider.isNotEmpty &&
        providerOf(model.id, providers: providers) != provider) {
      return false;
    }
    return true;
  }
}

/// Отбирает и сортирует модели из загруженного списка.
///
/// Без текста порядок задаёт [ModelListQuery.sort]. С текстом лучшие совпадения
/// идут первыми (имя и id весят больше провайдера, опечатки допускаются),
/// а выбранная сортировка решает, что показать при равной оценке.
List<LlmModelInfo> applyModelQuery(
  List<LlmModelInfo> models,
  ModelListQuery query, {
  List<LlmProviderDescriptor> providers = const [],
}) {
  final candidates = [
    for (final model in models)
      if (query.accepts(model, providers: providers)) model,
  ];
  final comparator = _comparatorOf(query.sort, providers);
  final terms = _searchTerms(query.search);
  if (terms.isEmpty) {
    candidates.sort(comparator);
    return candidates;
  }
  final scored = <({double score, LlmModelInfo model})>[];
  for (final model in candidates) {
    final score = _searchScore(model, terms, providers);
    if (score > 0) scored.add((score: score, model: model));
  }
  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : comparator(a.model, b.model);
  });
  return [for (final entry in scored) entry.model];
}

/// Для [ModelSort.provider] порядок — по алфавиту провайдеров, внутри группы по имени:
/// иначе группы менялись бы местами после каждого обновления каталога.
Comparator<LlmModelInfo> _comparatorOf(
  ModelSort sort,
  List<LlmProviderDescriptor> providers,
) => switch (sort) {
  ModelSort.provider => (a, b) {
    final byProvider = _compareNames(
      providerOf(a.id, providers: providers),
      providerOf(b.id, providers: providers),
    );
    return byProvider != 0 ? byProvider : _compareNames(a.name, b.name);
  },
  ModelSort.name => (a, b) => _compareNames(a.name, b.name),
  ModelSort.context => (a, b) => _thenByName(
    a,
    b,
    _compareNullsLast(a.contextLength, b.contextLength, descending: true),
  ),
  ModelSort.price => (a, b) => _thenByName(
    a,
    b,
    _compareNullsLast(totalPriceOf(a), totalPriceOf(b), descending: false),
  ),
  ModelSort.newest => (a, b) => _thenByName(
    a,
    b,
    _compareNullsLast(a.created, b.created, descending: true),
  ),
};

int _thenByName(LlmModelInfo a, LlmModelInfo b, int primary) =>
    primary != 0 ? primary : _compareNames(a.name, b.name);

/// Неизвестные значения уходят в конец списка независимо от направления.
int _compareNullsLast(num? a, num? b, {required bool descending}) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return descending ? b.compareTo(a) : a.compareTo(b);
}

/// Сравнение названий без учёта регистра с числами по значению:
/// `gpt-4` стоит перед `gpt-10`, а не после.
int _compareNames(String a, String b) {
  final left = a.toLowerCase();
  final right = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < left.length && j < right.length) {
    final leftDigit = _isDigit(left.codeUnitAt(i));
    final rightDigit = _isDigit(right.codeUnitAt(j));
    if (leftDigit && rightDigit) {
      final leftStart = i;
      final rightStart = j;
      while (i < left.length && _isDigit(left.codeUnitAt(i))) {
        i++;
      }
      while (j < right.length && _isDigit(right.codeUnitAt(j))) {
        j++;
      }
      final byNumber = _compareNumberText(
        _slice(left, leftStart, i),
        _slice(right, rightStart, j),
      );
      if (byNumber != 0) return byNumber;
      continue;
    }
    if (left.codeUnitAt(i) != right.codeUnitAt(j)) {
      return left.codeUnitAt(i).compareTo(right.codeUnitAt(j));
    }
    i++;
    j++;
  }
  final byRest = (left.length - i).compareTo(right.length - j);
  return byRest != 0 ? byRest : a.compareTo(b);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// Числа сравниваются по значению: длина без ведущих нулей, потом посимвольно.
/// Так длинные номера версий не переполняют `int`.
int _compareNumberText(String a, String b) {
  final left = _trimLeadingZeros(a);
  final right = _trimLeadingZeros(b);
  if (left.length != right.length) return left.length.compareTo(right.length);
  return left.compareTo(right);
}

String _trimLeadingZeros(String value) {
  var index = 0;
  while (index < value.length - 1 && value.codeUnitAt(index) == 0x30) {
    index++;
  }
  return _slice(value, index, value.length);
}

/// Срез по смещениям UTF-16: `substring` запрещён правилом `avoid-substring`.
String _slice(String text, int start, int end) =>
    String.fromCharCodes(text.codeUnits, start, end);

List<String> _searchTerms(String search) => [
  for (final term in normalizeSearchText(search).split(' '))
    if (term.isNotEmpty) term,
];

/// Средняя оценка терминов по полям модели. 0 — хотя бы один термин не найден.
///
/// Название весит больше id, id — больше провайдера: запрос `gpt` должен
/// находить `GPT-4o`, а не все модели OpenAI выше точного совпадения.
double _searchScore(
  LlmModelInfo model,
  List<String> terms,
  List<LlmProviderDescriptor> providers,
) {
  final fields = <(String, double)>[
    (model.name, 1),
    (modelIdForDisplay(model.id, providers: providers), 0.9),
    (model.id, 0.85),
    (providerOf(model.id, providers: providers), 0.7),
  ];
  // Тот же набор без пробелов: «gpt4o» находит «GPT-4o», где нормализация
  // заменяет дефис пробелом.
  final compact = [
    for (final (value, weight) in fields)
      (normalizeSearchText(value).replaceAll(' ', ''), weight * 0.95),
  ];
  var sum = 0.0;
  for (final term in terms) {
    final compactTerm = normalizeSearchText(term).replaceAll(' ', '');
    var best = 0.0;
    for (final (value, weight) in fields) {
      final score = scoreSearchText(value, term) * weight;
      if (score > best) best = score;
    }
    if (compactTerm.isNotEmpty) {
      for (final (value, weight) in compact) {
        final score = scoreSearchText(value, compactTerm) * weight;
        if (score > best) best = score;
      }
    }
    if (best <= 0) return 0;
    sum += best;
  }
  return sum / terms.length;
}
