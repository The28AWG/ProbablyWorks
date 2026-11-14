import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:pw_agent/core/data/saved_model_repository.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Статус выбранной модели относительно последнего успешного списка OpenRouter.
enum ModelStatus {
  /// Список ещё ни разу не загружен: проверить нельзя, модель показываем как есть.
  unknown,
  available,

  /// Список загружен, а модели в нём нет.
  unavailable,
}

/// Состояние каталога: список моделей в памяти, выбранные модели из БД и статус загрузки.
class ModelCatalogState extends Equatable {
  const ModelCatalogState({
    this.models = const [],
    this.syncedAt,
    this.loading = false,
    this.error,
    this.saved = const {},
    this.llamaCpp = const LlamaCppStatus(),
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

  /// Статус подключения к llama.cpp. Сервер не опрашивается, если провайдер выключен.
  final LlamaCppStatus llamaCpp;

  bool get loaded => syncedAt != null;

  /// Первая загрузка идёт: рядом с моделями, которых ещё не знаем, показываем спиннер.
  bool get initialLoading => loading && !loaded;

  LlmModelInfo? modelOf(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
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

  /// Название: из списка, иначе из сохранённых деталей, иначе id.
  String nameOf(String id) => modelOf(id)?.name ?? saved[id]?.name ?? id;

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
    LlamaCppStatus? llamaCpp,
  }) => ModelCatalogState(
    models: models ?? this.models,
    syncedAt: syncedAt ?? this.syncedAt,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    saved: saved ?? this.saved,
    llamaCpp: llamaCpp ?? this.llamaCpp,
  );

  @override
  List<Object?> get props => [
    models,
    syncedAt,
    loading,
    error,
    saved,
    llamaCpp,
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

/// Каталог моделей. Список OpenRouter живёт в памяти и обновляется при старте, по таймеру,
/// вручную и с повтором после ошибки. В БД попадают только выбранные модели ([remember]).
@lazySingleton
class ModelCatalogService implements ModelCatalogSource {
  ModelCatalogService(this._repository, this._llm);

  static final _log = Logger('ModelCatalog');

  /// Периодическое обновление, чтобы отметки `!` не отставали от OpenRouter.
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
  Future<bool> Function() _hasKey = () async => false;
  Future<bool> Function()? _hasProvider;

  /// Провайдер llama.cpp, если он есть среди зарегистрированных. Тестовые
  /// провайдеры интерфейс не реализуют, и статус остаётся значением по умолчанию.
  LlamaCppStatusProvider? get _llamaCpp =>
      // ignore: avoid-unrelated-type-assertions, MultiLlmProvider implements both interfaces.
      _llm is LlamaCppStatusProvider ? _llm as LlamaCppStatusProvider : null;

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

  /// Старт приложения: выбранные модели из БД, загрузка списка и периодическое обновление.
  /// [hasKey] проверяется перед каждой автоматической попыткой OpenRouter: без ключа сеть не трогаем.
  /// [hasProvider] — дополнительный провайдер (llama.cpp); по умолчанию проверяется его включённость.
  Future<void> start({
    required Future<bool> Function() hasKey,
    Future<bool> Function()? hasProvider,
  }) async {
    await loadSaved();
    _hasKey = hasKey;
    _hasProvider = hasProvider ?? _defaultHasProvider;
    _started = true;
    _periodic ??= Timer.periodic(_refreshEvery, (_) => _quietRefresh());
    _quietRefresh();
  }

  /// Проверка, что дополнительный провайдер включён. Не трогает сеть.
  Future<bool> _defaultHasProvider() {
    final provider = _llamaCpp;
    if (provider == null) return Future.value(false);
    return provider.isEnabled;
  }

  /// Выбранные модели из БД: доступны сразу, до загрузки списка.
  Future<void> loadSaved() async {
    final saved = await _repository.all();
    _emit(_state.copyWith(saved: {for (final model in saved) model.id: model}));
  }

  /// Пауза перед повтором после [failures] подряд идущих ошибок: растёт и не превышает последнюю.
  static Duration retryDelayFor(int failures) =>
      _retryDelays[failures < _retryDelays.length
          ? failures
          : _retryDelays.length - 1];

  /// Загружает список из OpenRouter. Параллельные вызовы делят один запрос.
  /// Ошибка выбрасывается наружу, прежний список сохраняется, а загрузка повторяется с паузой.
  @override
  Future<void> refresh() =>
      _refreshing ??= _load().whenComplete(() => _refreshing = null);

  /// Проверяет ключ OpenRouter запросом с авторизацией и возвращает его сведения.
  /// Список моделей ключ не подтверждает: он публичный.
  Future<LlmKeyInfo> checkKey() => _llm.checkKey();

  /// Проверяет доступность llama.cpp и обновляет статус в состоянии.
  /// Возвращает null, если провайдера llama.cpp нет среди зарегистрированных.
  Future<LlamaCppStatus?> checkLlamaCpp() async {
    final provider = _llamaCpp;
    if (provider == null) return null;
    final status = await provider.checkHealth();
    _emit(_state.copyWith(llamaCpp: status));
    return status;
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
      name: live?.name ?? known?.name ?? id,
      contextLength: live?.contextLength ?? known?.contextLength,
      supportsTools: live?.supportsTools ?? known?.supportsTools ?? false,
      inputModalities: live?.inputModalities ?? known?.inputModalities,
    );
  }

  Future<void> _load() async {
    _emit(_state.copyWith(loading: true));
    // Статус llama.cpp проверяем до списка: он не должен падать вместе с ним.
    final llamaCpp = await _llamaCpp?.checkHealth();
    if (llamaCpp != null) _emit(_state.copyWith(llamaCpp: llamaCpp));
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

  /// Автоматическое обновление (старт, таймер, повтор): без ключа OpenRouter
  /// и без включённого дополнительного провайдера ничего не делает.
  /// Ошибка уже записана в состоянии и залогирована, поэтому здесь её не пробрасываем.
  void _quietRefresh() => unawaited(
    _autoRefresh().catchError(
      (Object error) => _log.fine('background refresh skipped', error),
    ),
  );

  Future<void> _autoRefresh() async {
    if (await _hasKey()) {
      await refresh();
      return;
    }
    if (await (_hasProvider ?? _defaultHasProvider)()) await refresh();
  }

  void _emit(ModelCatalogState next) {
    _state = next;
    _changes.add(next);
  }
}
