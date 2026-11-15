import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llamadart/llamadart_connection.dart';
import 'package:pw_agent/providers/ai/local_models.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

/// Состояние раздела «Локальные модели».
class LocalModelsViewState extends Equatable {
  const LocalModelsViewState({
    this.models = const LocalModelsState(),
    this.runtime = const ModelRuntimeState(),
    this.loading = true,
    this.busy = false,
    this.error,
  });

  final LocalModelsState models;
  final ModelRuntimeState runtime;
  final bool loading;

  /// Идёт действие над средой: установка, удаление, сохранение параметров.
  final bool busy;
  final String? error;

  /// Состояние памяти модели по её локальному id.
  ModelRuntime? runtimeOf(String id) =>
      runtime.modelOf(llamadartDescriptor.globalModelId(id));

  LocalModelsViewState copyWith({
    LocalModelsState? models,
    ModelRuntimeState? runtime,
    bool? loading,
    bool? busy,
    String? error,
    bool clearError = false,
  }) => LocalModelsViewState(
    models: models ?? this.models,
    runtime: runtime ?? this.runtime,
    loading: loading ?? this.loading,
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  List<Object?> get props => [models, runtime, loading, busy, error];
}

/// Управление средой выполнения из настроек.
///
/// Раздел не зависит от включённости провайдера: файлы, параметры и очистка
/// работают всегда. Загрузка в память идёт через общий runtime-сервис, поэтому
/// бейджи совпадают с выбором модели и чипом чата.
class LocalModelsCubit extends Cubit<LocalModelsViewState> {
  LocalModelsCubit(this._source, this._runtime)
    : super(const LocalModelsViewState()) {
    _modelsSub = _source.watch().listen(
      (models) => emit(state.copyWith(models: models, loading: false)),
      onError: (Object error, StackTrace stack) =>
          emit(state.copyWith(loading: false, error: _messageOf(error))),
    );
    _runtimeSub = _runtime.watchRuntime().listen(
      (runtime) => emit(state.copyWith(runtime: runtime)),
      onError: (Object error, StackTrace stack) =>
          emit(state.copyWith(error: _messageOf(error))),
    );
  }

  final LocalModelsSource _source;
  final ModelRuntimeSource _runtime;
  late final StreamSubscription<LocalModelsState> _modelsSub;
  late final StreamSubscription<ModelRuntimeState> _runtimeSub;

  /// Перечитывает файлы с диска. Ошибка попадает в состояние.
  Future<void> load() async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      await _source.refresh();
      emit(state.copyWith(loading: false));
    } on Object catch (error) {
      emit(state.copyWith(loading: false, error: _messageOf(error)));
    }
  }

  Future<void> install(String source, {String? name, String? sha256}) =>
      _run(() => _source.startInstall(source, name: name, sha256: sha256));

  Future<void> importPath(String path, {String? name}) =>
      _run(() => _source.importPath(path, name: name));

  Future<void> cancelInstall(String id) =>
      _run(() => _source.cancelInstall(id));

  Future<void> delete(String id) => _run(() => _source.delete(id));

  Future<void> updateSettings(String id, LocalModelSettings settings) =>
      _run(() => _source.updateSettings(id, settings));

  Future<void> clearCache() => _run(_source.clearCache);

  Future<void> saveAutoUnload(int minutes) =>
      _run(() => _source.saveAutoUnload(minutes));

  Future<void> loadModel(String id) =>
      _run(() => _runtime.loadModel(llamadartDescriptor.globalModelId(id)));

  Future<void> unloadModel(String id) =>
      _run(() => _runtime.unloadModel(llamadartDescriptor.globalModelId(id)));

  void dismissError() => emit(state.copyWith(clearError: true));

  /// Общий путь действия: один флаг занятости и одна ошибка на раздел.
  Future<void> _run(Future<void> Function() action) async {
    if (state.busy) return;
    emit(state.copyWith(busy: true, clearError: true));
    try {
      await action();
    } on Object catch (error) {
      emit(state.copyWith(error: _messageOf(error)));
    } finally {
      emit(state.copyWith(busy: false));
    }
  }

  static String _messageOf(Object error) =>
      error is AppFailure ? error.message : '$error';

  @override
  Future<void> close() async {
    await _modelsSub.cancel();
    await _runtimeSub.cancel();
    return super.close();
  }
}
