import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pw_agent/agent/api/data_api.dart';
import 'package:pw_agent/core/error/app_failure.dart';

/// Состояние раздела «Данные» в настройках.
class DataState extends Equatable {
  const DataState({
    this.usage,
    this.loading = true,
    this.clearing = false,
    this.resetting = false,
    this.error,
  });

  /// Сводка истории. Null — ещё не загружена.
  final DataUsage? usage;
  final bool loading;

  /// Идёт очистка истории или сброс настроек. Обе операции несовместимы.
  final bool clearing;
  final bool resetting;
  final String? error;

  bool get busy => loading || clearing || resetting;

  DataState copyWith({
    DataUsage? usage,
    bool? loading,
    bool? clearing,
    bool? resetting,
    String? error,
    bool clearError = false,
  }) => DataState(
    usage: usage ?? this.usage,
    loading: loading ?? this.loading,
    clearing: clearing ?? this.clearing,
    resetting: resetting ?? this.resetting,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  List<Object?> get props => [usage, loading, clearing, resetting, error];
}

/// Загружает объём истории и выполняет необратимые операции раздела.
class DataCubit extends Cubit<DataState> {
  DataCubit(this._api) : super(const DataState());

  final DataApi _api;

  /// Перечитывает занятое место. Ошибка остаётся в состоянии.
  Future<void> load() async {
    if (isClosed) return;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final usage = await _api.usage();
      if (isClosed) return;
      emit(state.copyWith(usage: usage, loading: false, clearError: true));
    } on Object catch (error) {
      if (isClosed) return;
      emit(state.copyWith(loading: false, error: _messageOf(error)));
    }
  }

  /// Удаляет историю. Null при ошибке; в состоянии остаётся причина.
  Future<HistoryClearResult?> clearHistory({int? olderThanDays}) async {
    if (isClosed) return null;
    emit(state.copyWith(clearing: true, clearError: true));
    try {
      final result = await _api.clearHistory(olderThanDays: olderThanDays);
      final usage = await _refreshUsage();
      if (isClosed) return result;
      emit(
        state.copyWith(
          usage: usage ?? state.usage,
          clearing: false,
          clearError: true,
        ),
      );
      return result;
    } on Object catch (error) {
      if (!isClosed) {
        emit(state.copyWith(clearing: false, error: _messageOf(error)));
      }
      return null;
    }
  }

  /// Сбрасывает настройки агента. True — операция завершилась.
  Future<bool> resetSettings() async {
    if (isClosed) return false;
    emit(state.copyWith(resetting: true, clearError: true));
    try {
      await _api.resetSettings();
      final usage = await _refreshUsage();
      if (isClosed) return true;
      emit(
        state.copyWith(
          usage: usage ?? state.usage,
          resetting: false,
          clearError: true,
        ),
      );
      return true;
    } on Object catch (error) {
      if (!isClosed) {
        emit(state.copyWith(resetting: false, error: _messageOf(error)));
      }
      return false;
    }
  }

  /// Пересчитывает сводку после операции. Ошибка подсчёта не отменяет
  /// уже выполненную очистку или сброс: остаётся прежняя цифра.
  Future<DataUsage?> _refreshUsage() async {
    try {
      return await _api.usage();
    } on Object {
      return null;
    }
  }

  static String _messageOf(Object error) =>
      error is AppFailure ? error.message : '$error';
}
