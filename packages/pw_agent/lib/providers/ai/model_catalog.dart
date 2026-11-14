import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:pw_agent/core/data/saved_model_repository.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Статус выбранной модели относительно последнего успешного списка провайдеров.
enum ModelStatus {
  /// Список ещё ни разу не загружен: проверить нельзя, модель показываем как есть.
  unknown,
  available,

  /// Список загружен, а модели в нём нет.
  unavailable,
}

/// Состояние каталога: модели в памяти, выбранные модели из БД, провайдеры и их статусы.
class ModelCatalogState extends Equatable {
  const ModelCatalogState({
    this.models = const [],
    this.syncedAt,
    this.loading = false,
    this.error,
    this.saved = const {},
    this.providers = const [],
    this.providerStatuses = const {},
  });

  /// Список из последней успешной загрузки. Хранится только в памяти.
  final List<LlmModelInfo> models;

  /// Время последней успешной загрузки. Null — список ещё ни разу не загружался.
  final DateTime? syncedAt;

  /// Запрос в полёте.
  final bool loading;

  /// Ошибка последней попытки; null после успешной загрузки.
  final String? error;

  /// Выбранные модели с деталями (из БД). Нужны до загрузки списка и после того, как модель пропала.
  final Map<String, SavedModel> saved;

  /// Дескрипторы зарегистрированных провайдеров. Из них берутся подписи
  /// и префиксы моделей: UI не знает конкретных провайдеров.
  final List<LlmProviderDescriptor> providers;

  /// Статусы провайдеров по id. Обновляются без сети при старте и с сетью
  /// при обновлении каталога.
  final Map<String, LlmProviderStatus> providerStatuses;

  bool get loaded => syncedAt != null;

  /// Первая загрузка идёт: рядом с моделями, которых ещё не знаем, показываем спиннер.
  bool get initialLoading => loading && !loaded;

  /// Хоть один провайдер реально готов отдавать модели: включён, имеет
  /// обязательный ключ и для локального провайдера уже ответил на проверку.
  /// Сеть не требуется: используется последний известный статус.
  bool get hasUsableProvider {
    for (final descriptor in providers) {
      final status = providerStatuses[descriptor.id];
      if (status == null || !status.enabled) continue;
      if (descriptor.requiresApiKey) {
        if (status.apiKeySet) return true;
        continue;
      }
      if (status.available) return true;
    }
    return false;
  }

  /// Хоть один провайдер включён. Нужен, чтобы обновить каталог при открытии
  /// настроек до первой проверки доступности.
  bool get hasEnabledProvider {
    for (final descriptor in providers) {
      if (providerStatuses[descriptor.id]?.enabled ?? false) return true;
    }
    return false;
  }

  LlmModelInfo? modelOf(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// Провайдер модели по дескрипторам, с запасным правилом «часть до `/`».
  LlmProviderDescriptor? descriptorOf(String id) =>
      providerDescriptorOf(id, providers);

  /// Подпись провайдера модели: для провайдера с префиксом — его label,
  /// иначе часть id до `/` (upstream-провайдер OpenRouter).
  String providerOf(String id) {
    final descriptor = descriptorOf(id);
    if (descriptor != null && descriptor.modelPrefix.isNotEmpty) {
      return descriptor.label;
    }
    final slash = id.indexOf('/');
    return slash <= 0 ? id : charPrefix(id, slash);
  }

  /// id модели без служебного префикса провайдера.
  String modelIdForDisplay(String id) =>
      descriptorOf(id)?.localModelId(id) ?? id;

  /// Сколько моделей провайдера в текущем каталоге.
  int modelCountOf(String providerId) {
    var count = 0;
    for (final model in models) {
      if (descriptorOf(model.id)?.id == providerId) count++;
    }
    return count;
  }

  ModelStatus statusOf(String? id) {
    if (id == null || id.isEmpty || !loaded) return ModelStatus.unknown;
    return modelOf(id) == null
        ? ModelStatus.unavailable
        : ModelStatus.available;
  }

  /// Принимает ли модель файл: по каталогу, иначе по сохранённым деталям (см. [acceptsFileType]).
  bool acceptsFile(String id, String mimeType) => acceptsFileType(
    modelOf(id)?.inputModalities ?? saved[id]?.inputModalities,
    mimeType,
  );

  /// Название: из списка, иначе из сохранённых деталей, иначе id без префикса.
  String nameOf(String id) =>
      modelOf(id)?.name ?? saved[id]?.name ?? modelIdForDisplay(id);

  /// Название известно без загрузки списка: модель в списке или в сохранённых деталях.
  bool knowsName(String? id) =>
      id != null && (modelOf(id) != null || saved.containsKey(id));

  ModelCatalogState copyWith({
    List<LlmModelInfo>? models,
    DateTime? syncedAt,
    bool? loading,
    String? error,
    bool clearError = false,
    Map<String, SavedModel>? saved,
    List<LlmProviderDescriptor>? providers,
    Map<String, LlmProviderStatus>? providerStatuses,
  }) => ModelCatalogState(
    models: models ?? this.models,
    syncedAt: syncedAt ?? this.syncedAt,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    saved: saved ?? this.saved,
    providers: providers ?? this.providers,
    providerStatuses: providerStatuses ?? this.providerStatuses,
  );

  @override
  List<Object?> get props => [
    models,
    syncedAt,
    loading,
    error,
    saved,
    providers,
    providerStatuses,
  ];
}

/// Источник каталога моделей для диалогов выбора: локальный сервис или
/// удалённый профиль агента. Состояние и обновление отдают сами данные,
/// поэтому UI не зависит от конкретной реализации каталога.
abstract interface class ModelCatalogSource {
  ModelCatalogState get state;
  Stream<ModelCatalogState> watch();
  Future<void> refresh();
}

/// Каталог моделей. Список провайдеров живёт в памяти и обновляется при
/// старте, по таймеру, вручную и с повтором после ошибки. В БД попадают
/// только выбранные модели ([remember]).
@lazySingleton
class ModelCatalogService implements ModelCatalogSource {
  ModelCatalogService(this._repository, this._llm);

  static final _log = Logger('ModelCatalog');

  /// Периодическое обновление, чтобы отметки `!` не отставали от каталога.
  static const _refreshEvery = Duration(hours: 6);

  /// Паузы между повторами после ошибки; дальше — последняя пауза.
  static const _retryDelays = [
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  final SavedModelRepository _repository;
  final LlmProvider _llm;
  final _changes = StreamController<ModelCatalogState>.broadcast();
  ModelCatalogState _state = const ModelCatalogState();
  Future<void>? _refreshing;
  Timer? _retry;
  Timer? _periodic;
  int _failures = 0;
  bool _started = false;

  @override
  ModelCatalogState get state => _state;

  /// Текущее состояние и все последующие изменения.
  @override
  Stream<ModelCatalogState> watch() => Stream.multi((controller) {
    controller.add(_state);
    final sub = _changes.stream.listen(
      controller.add,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  /// Старт приложения: выбранные модели из БД, настройки провайдеров
  /// и периодическое обновление каталога.
  ///
  /// Сеть трогаем только если есть настроенный провайдер. Проверка идёт
  /// через дескрипторы и не знает конкретных имён.
  Future<void> start() async {
    await loadSaved();
    await loadProviderConfigs();
    _started = true;
    _periodic ??= Timer.periodic(_refreshEvery, (_) => _quietRefresh());
    _quietRefresh();
  }

  /// Выбранные модели из БД: доступны сразу, до загрузки списка.
  Future<void> loadSaved() async {
    final saved = await _repository.all();
    _emit(_state.copyWith(saved: {for (final model in saved) model.id: model}));
  }

  /// Настройки провайдеров без сети: включённость, адрес и наличие ключа.
  /// Нужны экрану настроек до первой проверки доступности.
  Future<void> loadProviderConfigs() async {
    final statuses = await _llm.configStatuses();
    _emit(
      _state.copyWith(
        providers: _llm.providers,
        providerStatuses: _mergeStatuses(_state.providerStatuses, statuses),
      ),
    );
  }

  /// Есть ли провайдер, готовый отдавать модели. Состояние каталога знает
  /// результат последней проверки; если проверки ещё не было, считаем
  /// готовым только провайдера с обязательным ключом. Сеть здесь не трогаем.
  Future<bool> get hasUsableProvider async {
    if (_state.hasUsableProvider) return true;
    final statuses = await _llm.configStatuses();
    for (final descriptor in _llm.providers) {
      if (!descriptor.requiresApiKey) continue;
      final status = _statusOf(statuses, descriptor.id);
      if (status == null || !status.enabled) continue;
      if (status.apiKeySet) return true;
    }
    return false;
  }

  /// Включён ли хоть один провайдер. Нужен для автоматического обновления:
  /// проверка доступности идёт уже внутри [refresh].
  Future<bool> get hasEnabledProvider async {
    final statuses = await _llm.configStatuses();
    for (final descriptor in _llm.providers) {
      final status = _statusOf(statuses, descriptor.id);
      if (status != null && status.enabled) return true;
    }
    return false;
  }

  /// Пауза перед повтором после [failures] подряд идущих ошибок: растёт и не превышает последнюю.
  static Duration retryDelayFor(int failures) =>
      _retryDelays[failures < _retryDelays.length
          ? failures
          : _retryDelays.length - 1];

  /// Загружает список из всех провайдеров и обновляет их статусы.
  /// Параллельные вызовы делят один запрос. Ошибка выбрасывается наружу,
  /// прежний список сохраняется, а загрузка повторяется с паузой.
  @override
  Future<void> refresh() =>
      _refreshing ??= _load().whenComplete(() => _refreshing = null);

  /// Проверяет всех провайдеров и обновляет статусы в состоянии.
  Future<List<LlmProviderStatus>> refreshStatuses() async {
    final statuses = await _llm.statuses();
    _emit(
      _state.copyWith(
        providers: _llm.providers,
        providerStatuses: _mergeStatuses(_state.providerStatuses, statuses),
      ),
    );
    return statuses;
  }

  /// Проверяет одного провайдера. Null — провайдер не зарегистрирован.
  Future<LlmProviderStatus?> checkProvider(String providerId) async {
    final statuses = await refreshStatuses();
    return _statusOf(statuses, providerId);
  }

  /// Запоминает выбранные модели с деталями. Если модели нет в загруженном списке,
  /// сохраняются только id и уже известные данные.
  Future<void> remember(Iterable<String> ids) => _store([
    for (final id in ids)
      if (id.isNotEmpty) _detailsOf(id),
  ]);

  SavedModel _detailsOf(String id) {
    final live = _state.modelOf(id);
    final known = _state.saved[id];
    return SavedModel(
      id: id,
      name: live?.name ?? known?.name ?? _state.modelIdForDisplay(id),
      contextLength: live?.contextLength ?? known?.contextLength,
      supportsTools: live?.supportsTools ?? known?.supportsTools ?? false,
      inputModalities: live?.inputModalities ?? known?.inputModalities,
    );
  }

  Future<void> _load() async {
    _emit(_state.copyWith(loading: true));
    // Настройки читаем до сети: даже если провайдер недоступен, экран
    // настроек должен показать его адрес и наличие ключа.
    await loadProviderConfigs();
    // Статусы проверяем до списка: ошибка одного провайдера не должна
    // скрывать модели другого.
    try {
      await refreshStatuses();
    } on Object catch (error, stack) {
      _log.warning('provider status check failed', error, stack);
    }
    final List<LlmModelInfo> listed;
    try {
      listed = await _llm.listModels();
      // Пустой ответ не считаем успехом: иначе сбой выглядел бы как исчезновение всех моделей.
      if (listed.isEmpty) {
        throw const LlmFailure('No AI provider returned a model list');
      }
    } on Object catch (error, stack) {
      _log.warning('model list refresh failed', error, stack);
      _emit(_state.copyWith(loading: false, error: '$error'));
      _scheduleRetry();
      rethrow;
    }
    _retry?.cancel();
    _failures = 0;
    _emit(
      _state.copyWith(
        models: listed,
        providerStatuses: _withModelCounts(_state.providerStatuses, listed),
        syncedAt: DateTime.now(),
        loading: false,
        clearError: true,
      ),
    );
    // Детали выбранных моделей, которые всё ещё есть в списке, обновляем (название, tool calling).
    await _store([
      for (final model in listed)
        if (_state.saved.containsKey(model.id)) _detailsOf(model.id),
    ]);
  }

  /// Объединяет статусы по id, не теряя результат последней проверки.
  static Map<String, LlmProviderStatus> _mergeStatuses(
    Map<String, LlmProviderStatus> current,
    List<LlmProviderStatus> incoming,
  ) {
    final result = {...current};
    for (final status in incoming) {
      result[status.id] = mergeProviderStatus(current[status.id], status);
    }
    return result;
  }

  /// Проставляет количество моделей каждого провайдера по свежему списку.
  Map<String, LlmProviderStatus> _withModelCounts(
    Map<String, LlmProviderStatus> statuses,
    List<LlmModelInfo> models,
  ) {
    final counts = <String, int>{};
    for (final model in models) {
      final descriptor = providerDescriptorOf(model.id, _state.providers);
      if (descriptor == null) continue;
      counts[descriptor.id] = (counts[descriptor.id] ?? 0) + 1;
    }
    return {
      for (final entry in statuses.entries)
        entry.key: entry.value.copyWith(modelCount: counts[entry.key]),
    };
  }

  static LlmProviderStatus? _statusOf(
    List<LlmProviderStatus> statuses,
    String id,
  ) {
    for (final status in statuses) {
      if (status.id == id) return status;
    }
    return null;
  }

  /// Пишет только изменившиеся детали: без лишних записей в БД.
  Future<void> _store(Iterable<SavedModel> models) async {
    final byId = {for (final model in models) model.id: model};
    final changed = [
      for (final model in byId.values)
        if (_state.saved[model.id] != model) model,
    ];
    if (changed.isEmpty) return;
    await _repository.save(changed);
    _emit(
      _state.copyWith(
        saved: {..._state.saved, for (final model in changed) model.id: model},
      ),
    );
  }

  /// Повтор только после старта приложения: в тестах и до [start] таймеры не создаются.
  void _scheduleRetry() {
    if (!_started) return;
    _retry?.cancel();
    _retry = Timer(retryDelayFor(_failures++), _quietRefresh);
  }

  /// Автоматическое обновление (старт, таймер, повтор): без настроенного
  /// провайдера сеть не трогаем. Ошибка уже записана в состоянии и
  /// залогирована, поэтому здесь её не пробрасываем.
  void _quietRefresh() => unawaited(
    _autoRefresh().catchError(
      (Object error) => _log.fine('background refresh skipped', error),
    ),
  );

  Future<void> _autoRefresh() async {
    if (await hasEnabledProvider) await refresh();
  }

  void _emit(ModelCatalogState next) {
    _state = next;
    _changes.add(next);
  }
}
