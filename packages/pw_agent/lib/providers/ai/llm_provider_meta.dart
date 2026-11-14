import 'package:equatable/equatable.dart';
import 'package:pw_agent/core/util/char_substring.dart';

/// Статическое описание LLM-провайдера.
///
/// Дескриптор — единственное место, где провайдер сообщает о себе всё,
/// что нужно каталогу, настройкам и интерфейсу: стабильный id, подпись,
/// префикс моделей и поддержку полей настройки. Новый провайдер добавляет
/// свой дескриптор и регистрируется в [LlmProviderRegistry]; общие слои
/// не должны знать его имени.
class LlmProviderDescriptor extends Equatable {
  const LlmProviderDescriptor({
    required this.id,
    required this.label,
    this.modelPrefix = '',
    this.defaultBaseUrl,
    this.requiresApiKey = false,
    this.supportsApiKey = true,
    this.supportsBaseUrl = false,
    this.supportsEnabledToggle = true,
    this.supportsKeyInfo = false,
    this.apiKeyExample,
  });

  /// Стабильный id провайдера: используется в API, настройках и секретах.
  final String id;

  /// Подпись для интерфейса. Это данные, а не ключ локализации: новый
  /// провайдер не требует правок `arb`.
  final String label;

  /// Префикс id моделей в общем каталоге. Пустой — модели провайдера
  /// занимают пространство id без префикса (OpenRouter).
  final String modelPrefix;

  /// Адрес по умолчанию, если пользователь не задал свой.
  final String? defaultBaseUrl;

  /// Без ключа провайдер не считается настроенным: guard и онбординг
  /// не пустят в приложение, пока ключ не сохранён.
  final bool requiresApiKey;

  /// В интерфейсе показывается поле ключа.
  final bool supportsApiKey;

  /// В интерфейсе показывается поле адреса сервера.
  final bool supportsBaseUrl;

  /// В интерфейсе показывается переключатель «включён».
  final bool supportsEnabledToggle;

  /// Провайдер отдаёт метаданные ключа (лимит, расход, срок). Для таких
  /// провайдеров настройки показывают [LlmKeyInfo].
  final bool supportsKeyInfo;

  /// Пример формата ключа для подсказки в поле ввода. Null — общая подсказка.
  final String? apiKeyExample;

  /// Id модели в общем каталоге: префикс плюс локальный id.
  String globalModelId(String localId) =>
      modelPrefix.isEmpty ? localId : '$modelPrefix$localId';

  /// Локальный id без префикса. Id другого провайдера возвращается как есть.
  String localModelId(String id) =>
      modelPrefix.isNotEmpty && id.startsWith(modelPrefix)
      ? charFrom(id, modelPrefix.length)
      : id;

  /// Принадлежит ли id этому провайдеру.
  bool ownsModel(String id) =>
      modelPrefix.isEmpty || id.startsWith(modelPrefix);

  @override
  List<Object?> get props => [
    id,
    label,
    modelPrefix,
    defaultBaseUrl,
    requiresApiKey,
    supportsApiKey,
    supportsBaseUrl,
    supportsEnabledToggle,
    supportsKeyInfo,
    apiKeyExample,
  ];
}

/// Настройки провайдера, прочитанные из хранилища.
///
/// Содержит секрет, поэтому не сериализуется и не попадает в состояние
/// интерфейса: наружу отдаётся только [LlmProviderStatus].
class LlmProviderConfig extends Equatable {
  const LlmProviderConfig({this.enabled = true, this.baseUrl, this.apiKey});

  /// Провайдер включён. Выключенный не опрашивается и не попадает в каталог.
  final bool enabled;

  /// Адрес сервера, уже с подставленным значением по умолчанию.
  final String? baseUrl;

  /// Ключ доступа. Null или пустая строка — ключа нет.
  final String? apiKey;

  bool get hasApiKey => apiKey != null && apiKey!.isNotEmpty;

  /// Последние три символа ключа для маски в UI. Пусто — ключа нет.
  String get apiKeyTail {
    final key = apiKey;
    if (key == null || key.isEmpty) return '';
    final runes = key.runes.toList();
    return String.fromCharCodes(
      runes.skip(runes.length > 3 ? runes.length - 3 : 0),
    );
  }

  @override
  List<Object?> get props => [enabled, baseUrl, apiKey];
}

/// Сведения о ключе сервиса: что показывает экран настроек. Все суммы в USD.
class LlmKeyInfo extends Equatable {
  const LlmKeyInfo({
    required this.label,
    required this.usage,
    this.limit,
    this.limitRemaining,
    this.limitReset,
    this.isFreeTier = false,
    this.expiresAt,
  });

  /// Метка ключа, которую сервис выдаёт сам (обычно маска вида `sk-or-v1-...`).
  final String label;

  /// Всего потрачено по ключу.
  final double usage;

  /// Лимит ключа; null — без лимита.
  final double? limit;

  /// Остаток лимита; null — без лимита.
  final double? limitRemaining;

  /// Период сброса лимита (`monthly`, `weekly`, ...); null — лимит не сбрасывается.
  final String? limitReset;

  final bool isFreeTier;

  /// Дата истечения ключа; null — ключ бессрочный.
  final DateTime? expiresAt;

  @override
  List<Object?> get props => [
    label,
    usage,
    limit,
    limitRemaining,
    limitReset,
    isFreeTier,
    expiresAt,
  ];
}

/// Статус провайдера для интерфейса и API.
///
/// Не содержит ключа: только признак, что он задан, и маску. [error] —
/// причина последней неудачной проверки или сохранения; после успеха null.
class LlmProviderStatus extends Equatable {
  const LlmProviderStatus({
    required this.id,
    this.enabled = true,
    this.baseUrl,
    this.apiKeySet = false,
    this.apiKeyTail = '',
    this.available = false,
    this.modelCount,
    this.error,
    this.checkedAt,
    this.keyInfo,
  });

  /// id провайдера из [LlmProviderDescriptor.id].
  final String id;

  /// Провайдер включён в настройках.
  final bool enabled;

  /// Адрес, который сейчас опрашивается. Null — у провайдера нет адреса.
  final String? baseUrl;

  /// Ключ задан в `SecretStore`.
  final bool apiKeySet;

  /// Последние три символа ключа для маски.
  final String apiKeyTail;

  /// Сервис ответил на проверку.
  final bool available;

  /// Сколько моделей провайдер отдал в последней проверке. Null — неизвестно.
  final int? modelCount;

  /// Причина последней неудачной проверки; null после успешной.
  final String? error;

  /// Время последней проверки. Null — проверки ещё не было.
  final DateTime? checkedAt;

  /// Метаданные ключа, если провайдер их умеет. Null — нет данных.
  final LlmKeyInfo? keyInfo;

  LlmProviderStatus copyWith({
    String? id,
    bool? enabled,
    String? baseUrl,
    bool? apiKeySet,
    String? apiKeyTail,
    bool? available,
    int? modelCount,
    String? error,
    bool clearError = false,
    DateTime? checkedAt,
    LlmKeyInfo? keyInfo,
    bool clearKeyInfo = false,
  }) => LlmProviderStatus(
    id: id ?? this.id,
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKeySet: apiKeySet ?? this.apiKeySet,
    apiKeyTail: apiKeyTail ?? this.apiKeyTail,
    available: available ?? this.available,
    modelCount: modelCount ?? this.modelCount,
    error: clearError ? null : (error ?? this.error),
    checkedAt: checkedAt ?? this.checkedAt,
    keyInfo: clearKeyInfo ? null : (keyInfo ?? this.keyInfo),
  );

  @override
  List<Object?> get props => [
    id,
    enabled,
    baseUrl,
    apiKeySet,
    apiKeyTail,
    available,
    modelCount,
    error,
    checkedAt,
    keyInfo,
  ];
}

/// Сливает новый статус провайдера с предыдущим.
///
/// Конфигурация без сети приходит с `checkedAt == null`. Если настройки
/// не изменились, сохраняем результат последней проверки: иначе UI
/// показывал бы «не отвечает» вместо реальной причины. Изменение
/// включённости, адреса или ключа сбрасывает старую проверку.
LlmProviderStatus mergeProviderStatus(
  LlmProviderStatus? previous,
  LlmProviderStatus incoming,
) {
  if (previous == null) return incoming;
  final changed =
      incoming.enabled != previous.enabled ||
      incoming.baseUrl != previous.baseUrl ||
      incoming.apiKeySet != previous.apiKeySet ||
      incoming.apiKeyTail != previous.apiKeyTail;
  final keepCheck = incoming.checkedAt == null && !changed;
  return LlmProviderStatus(
    id: incoming.id,
    enabled: incoming.enabled,
    baseUrl: incoming.baseUrl,
    apiKeySet: incoming.apiKeySet,
    apiKeyTail: incoming.apiKeyTail,
    available: keepCheck ? previous.available : incoming.available,
    modelCount: incoming.modelCount ?? (keepCheck ? previous.modelCount : null),
    error: keepCheck ? previous.error : incoming.error,
    checkedAt: incoming.checkedAt ?? (keepCheck ? previous.checkedAt : null),
    keyInfo: incoming.apiKeySet ? (incoming.keyInfo ?? previous.keyInfo) : null,
  );
}

/// Находит дескриптор, которому принадлежит id модели.
///
/// Префиксные провайдеры проверяются первыми: иначе провайдер без префикса
/// «забрал» бы чужие id. Если ни один дескриптор не подошёл, возвращает null,
/// и вызывающая сторона использует запасное правило (часть до `/`).
LlmProviderDescriptor? providerDescriptorOf(
  String id,
  List<LlmProviderDescriptor> descriptors,
) {
  for (final descriptor in descriptors) {
    if (descriptor.modelPrefix.isNotEmpty && descriptor.ownsModel(id)) {
      return descriptor;
    }
  }
  for (final descriptor in descriptors) {
    if (descriptor.modelPrefix.isEmpty) return descriptor;
  }
  return null;
}
