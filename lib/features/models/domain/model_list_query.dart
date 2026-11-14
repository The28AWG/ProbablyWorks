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
  return labels.toList()..sort();
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

  final String search;
  final bool toolsOnly;
  final bool freeOnly;
  final String provider;
  final ModelSort sort;

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
    final text = search.trim().toLowerCase();
    if (text.isEmpty) return true;
    return model.id.toLowerCase().contains(text) ||
        model.name.toLowerCase().contains(text);
  }
}

/// Отбирает и сортирует модели из загруженного списка.
List<LlmModelInfo> applyModelQuery(
  List<LlmModelInfo> models,
  ModelListQuery query, {
  List<LlmProviderDescriptor> providers = const [],
}) {
  final result = [
    for (final model in models)
      if (query.accepts(model, providers: providers)) model,
  ];
  final comparator = _comparatorOf(query.sort);
  if (comparator != null) result.sort(comparator);
  return result;
}

/// Для [ModelSort.provider] порядок задаёт каталог (по имени), группы строит диалог.
Comparator<LlmModelInfo>? _comparatorOf(ModelSort sort) => switch (sort) {
  ModelSort.provider => null,
  ModelSort.name => _byName,
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

int _byName(LlmModelInfo a, LlmModelInfo b) =>
    a.name.toLowerCase().compareTo(b.name.toLowerCase());

int _thenByName(LlmModelInfo a, LlmModelInfo b, int primary) =>
    primary != 0 ? primary : _byName(a, b);

/// Неизвестные значения уходят в конец списка независимо от направления.
int _compareNullsLast(num? a, num? b, {required bool descending}) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return descending ? b.compareTo(a) : a.compareTo(b);
}
