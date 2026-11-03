import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:probably_works/core/data/saved_model_repository.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

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
  }) => ModelCatalogState(
    models: models ?? this.models,
    syncedAt: syncedAt ?? this.syncedAt,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    saved: saved ?? this.saved,
  );

  @override
  List<Object?> get props => [models, syncedAt, loading, error, saved];
}

/// Каталог моделей. Список OpenRouter живёт в памяти и обновляется при старте, по таймеру,
/// вручную и с повтором после ошибки. В БД попадают только выбранные модели ([remember]).
@lazySingleton
class ModelCatalogService {
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

  ModelCatalogState get state => _state;

  /// Текущее состояние и все последующие изменения.
  Stream<ModelCatalogState> watch() => Stream.multi((controller) {
    controller.add(_state);
    final sub = _changes.stream.listen(
      controller.add,
      onDone: controller.close,
    );
    controller.onCancel = sub.cancel;
  });

  /// Старт приложения: выбранные модели из БД, загрузка списка и периодическое обновление.
  /// [hasKey] проверяется перед каждой автоматической попыткой: без ключа сеть не трогаем и не повторяем.
  Future<void> start({required Future<bool> Function() hasKey}) async {
    await loadSaved();
    _hasKey = hasKey;
    _started = true;
    _periodic ??= Timer.periodic(_refreshEvery, (_) => _quietRefresh());
    _quietRefresh();
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
  Future<void> refresh() =>
      _refreshing ??= _load().whenComplete(() => _refreshing = null);

  /// Проверяет ключ запросом с авторизацией. Список моделей ключ не подтверждает: он публичный.
  Future<void> checkKey() => _llm.checkKey();

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
    final List<LlmModelInfo> listed;
    try {
      listed = await _llm.listModels();
      // Пустой ответ не считаем успехом: иначе сбой выглядел бы как исчезновение всех моделей.
      if (listed.isEmpty) {
        throw const LlmFailure('OpenRouter returned an empty model list');
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

  /// Автоматическое обновление (старт, таймер, повтор): без ключа ничего не делает.
  /// Ошибка уже записана в состоянии и залогирована, поэтому здесь её не пробрасываем.
  void _quietRefresh() => unawaited(
    _autoRefresh().catchError(
      (Object error) => _log.fine('background refresh skipped', error),
    ),
  );

  Future<void> _autoRefresh() async {
    if (!await _hasKey()) return;
    await refresh();
  }

  void _emit(ModelCatalogState next) {
    _state = next;
    _changes.add(next);
  }
}
