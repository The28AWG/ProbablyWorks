/// Сервис наблюдения за моделями: объединяет runtime-адаптеры провайдеров.
///
/// Сервис не знает имён провайдеров и их протоколов. Адаптер отдаёт
/// [ProviderRuntimeState] с глобальными id моделей, а сервис только сливает
/// состояния, переподключает потоки и выполняет действия load/unload.
library;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llm_provider_meta.dart';
import 'package:pw_agent/providers/ai/llm_provider_registry.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

/// Сводное состояние runtime всех провайдеров.
class ModelRuntimeService implements ModelRuntimeSource {
  ModelRuntimeService(this._registry);

  static final _log = Logger('ModelRuntime');

  /// Паузы переподключения: растут до последней и дальше не увеличиваются.
  static const _retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  final LlmProviderRegistry _registry;
  final _changes = StreamController<ModelRuntimeState>.broadcast();
  final _states = <String, ProviderRuntimeState>{};
  final _subs = <String, StreamSubscription<ProviderRuntimeState>>{};
  final _retryTimers = <String, Timer>{};
  final _failures = <String, int>{};
  ModelRuntimeState _state = const ModelRuntimeState();
  var _started = false;

  @override
  ModelRuntimeState get runtime {
    unawaited(ensureStarted());
    return _state;
  }

  @override
  Stream<ModelRuntimeState> watchRuntime() {
    unawaited(ensureStarted());
    return Stream.multi((controller) {
      controller.add(_state);
      final sub = _changes.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    });
  }

  /// Запускает наблюдение, если оно ещё не запущено. Повторные вызовы
  /// безопасны и не создают второй набор подписок.
  Future<void> ensureStarted() async {
    if (_started) return;
    _started = true;
    _connectAll();
  }

  /// Полный перезапуск: нужен после смены адреса, ключа или включённости
  /// провайдера. Старые снимки сбрасываются, чтобы UI не показывал устаревшее
  /// состояние другого сервера.
  @override
  Future<void> refreshRuntime() async {
    await _stopAll();
    _failures.clear();
    _states.clear();
    _emit();
    _started = true;
    _connectAll();
  }

  /// Перезапускает только один провайдер, если он зарегистрирован.
  Future<void> restartProvider(String providerId) async {
    for (final adapter in _registry.runtimeProviders) {
      if (!adapter.providers.any((item) => item.id == providerId)) continue;
      await _stopProvider(providerId);
      _states.remove(providerId);
      _emit();
      _started = true;
      _connect(adapter);
      return;
    }
  }

  @override
  Future<void> loadModel(String modelId) => _runAction(
    modelId,
    phase: ModelRuntimePhase.loading,
    action: (adapter, localId) => adapter.loadRuntimeModel(localId),
    successPhase: null,
  );

  @override
  Future<void> unloadModel(String modelId) => _runAction(
    modelId,
    phase: ModelRuntimePhase.unloading,
    action: (adapter, localId) => adapter.unloadRuntimeModel(localId),
    successPhase: ModelRuntimePhase.unloaded,
  );

  Future<void> _runAction(
    String modelId, {
    required ModelRuntimePhase phase,
    required Future<void> Function(
      LlmModelRuntimeProvider adapter,
      String localModelId,
    )
    action,
    required ModelRuntimePhase? successPhase,
  }) async {
    final target = _actionFor(modelId);
    if (target == null) {
      throw LlmFailure('Model $modelId does not support runtime control');
    }
    final now = DateTime.now().toUtc();
    _patchModel(
      target.descriptor.id,
      ModelRuntime(
        modelId: modelId,
        phase: phase,
        startedAt: now,
        updatedAt: now,
        reported: false,
      ),
    );
    try {
      await action(target.adapter, target.localModelId);
    } on Object catch (error, stack) {
      _patchModel(
        target.descriptor.id,
        ModelRuntime(
          modelId: modelId,
          phase: ModelRuntimePhase.failed,
          error: _messageOf(error),
          updatedAt: DateTime.now().toUtc(),
          reported: false,
        ),
      );
      Error.throwWithStackTrace(error, stack);
    }
    final capabilities = _states[target.descriptor.id]?.capabilities;
    final next =
        successPhase ??
        (capabilities?.reportsState == true
            ? ModelRuntimePhase.loading
            : ModelRuntimePhase.loaded);
    if (next == ModelRuntimePhase.loading) return;
    _patchModel(
      target.descriptor.id,
      ModelRuntime(
        modelId: modelId,
        phase: next,
        updatedAt: DateTime.now().toUtc(),
        reported: false,
      ),
    );
  }

  void _connectAll() {
    for (final adapter in _registry.runtimeProviders) {
      _connect(adapter);
    }
  }

  void _connect(LlmModelRuntimeProvider adapter) {
    final descriptor = adapter.providers.firstOrNull;
    if (descriptor == null) return;
    final providerId = descriptor.id;
    if (_subs.containsKey(providerId)) return;
    _retryTimers.remove(providerId)?.cancel();
    unawaited(_connectIfEnabled(adapter, descriptor.id));
  }

  Future<void> _connectIfEnabled(
    LlmModelRuntimeProvider adapter,
    String providerId,
  ) async {
    try {
      if (!await adapter.runtimeEnabled) {
        _states.remove(providerId);
        _emit();
        return;
      }
    } on Object catch (error) {
      _log.fine('runtime config for $providerId is unavailable', error);
      _scheduleRetry(adapter, providerId);
      return;
    }
    if (_subs.containsKey(providerId)) return;
    final StreamSubscription<ProviderRuntimeState> sub;
    try {
      sub = adapter.watchRuntime().listen(
        (state) {
          _failures[providerId] = 0;
          _states[state.providerId] = state;
          _emit();
        },
        onError: (Object error, StackTrace stack) {
          _log.warning('runtime stream for $providerId failed', error, stack);
          _markUnavailable(providerId, error);
          // Микрозадача нужна, если поток завершился ещё во время listen:
          // подписка должна успеть попасть в _subs до переподключения.
          unawaited(
            Future<void>.microtask(() => _scheduleRetry(adapter, providerId)),
          );
        },
        onDone: () {
          _markUnavailable(
            providerId,
            const LlmFailure('runtime stream closed'),
          );
          unawaited(
            Future<void>.microtask(() => _scheduleRetry(adapter, providerId)),
          );
        },
      );
    } on Object catch (error, stack) {
      _log.warning('runtime stream for $providerId cannot start', error, stack);
      _scheduleRetry(adapter, providerId);
      return;
    }
    _subs[providerId] = sub;
  }

  /// Связь с провайдером потеряна: последний снимок больше не считается
  /// живым. Иначе чип и настройки показывали бы «загружена» у упавшего
  /// сервера. Возможности сохраняем, чтобы после переподключения UI сразу
  /// знал, что runtime поддерживается.
  void _markUnavailable(String providerId, Object error) {
    final current = _states[providerId];
    if (current == null) return;
    _states[providerId] = current.copyWith(
      models: const {},
      error: _messageOf(error),
      updatedAt: DateTime.now().toUtc(),
    );
    _emit();
  }

  void _scheduleRetry(LlmModelRuntimeProvider adapter, String providerId) {
    unawaited(_subs.remove(providerId)?.cancel());
    if (!_started || _retryTimers.containsKey(providerId)) return;
    final failures = _failures[providerId] ?? 0;
    _failures[providerId] = failures + 1;
    final delay =
        _retryDelays[failures < _retryDelays.length
            ? failures
            : _retryDelays.length - 1];
    _retryTimers[providerId] = Timer(delay, () {
      _retryTimers.remove(providerId);
      _connect(adapter);
    });
  }

  Future<void> _stopAll() async {
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    final subs = _subs.values.toList(growable: false);
    _subs.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
  }

  Future<void> _stopProvider(String providerId) async {
    _retryTimers.remove(providerId)?.cancel();
    final sub = _subs.remove(providerId);
    await sub?.cancel();
    _failures[providerId] = 0;
  }

  ({
    LlmModelRuntimeProvider adapter,
    LlmProviderDescriptor descriptor,
    String localModelId,
  })?
  _actionFor(String modelId) {
    for (final adapter in _registry.runtimeProviders) {
      for (final descriptor in adapter.providers) {
        if (descriptor.ownsModel(modelId)) {
          return (
            adapter: adapter,
            descriptor: descriptor,
            localModelId: descriptor.localModelId(modelId),
          );
        }
      }
    }
    return null;
  }

  /// Локальное обновление записи без ожидания SSE. Нужно, чтобы кнопка
  /// сразу показала «Загружается»/«Выгружается», а не замерла.
  void _patchModel(String providerId, ModelRuntime model) {
    final current = _states[providerId];
    final models = Map<String, ModelRuntime>.of(current?.models ?? const {});
    models[model.modelId] = model;
    _states[providerId] = ProviderRuntimeState(
      providerId: providerId,
      capabilities: current?.capabilities ?? ModelRuntimeCapabilities.none,
      models: models,
      error: current?.error,
      updatedAt: DateTime.now().toUtc(),
    );
    _emit();
  }

  String _messageOf(Object error) =>
      error is LlmFailure ? error.message : '$error';

  void _emit() {
    _state = ModelRuntimeState(
      providers: {
        for (final entry in _states.entries)
          if (entry.value.capabilities.isSupported) entry.key: entry.value,
      },
    );
    if (!_changes.isClosed) _changes.add(_state);
  }
}
