import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:pw_agent/agent/api/push_api.dart';

/// Состояние настроек push-уведомлений профиля.
class PushNotificationsState extends Equatable {
  const PushNotificationsState({
    this.settings = const PushSettings(),
    this.loading = true,
    this.saving = false,
    this.error,
  });

  final PushSettings settings;
  final bool loading;
  final bool saving;
  final String? error;

  PushNotificationsState copyWith({
    PushSettings? settings,
    bool? loading,
    bool? saving,
    String? error,
    bool clearError = false,
  }) => PushNotificationsState(
    settings: settings ?? this.settings,
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  List<Object?> get props => [settings, loading, saving, error];
}

class PushNotificationsCubit extends Cubit<PushNotificationsState> {
  PushNotificationsCubit(this._api) : super(const PushNotificationsState());

  final PushApi _api;

  Future<void> load() async {
    try {
      final settings = await _api.pushSettings();
      emit(
        state.copyWith(settings: settings, loading: false, clearError: true),
      );
    } on Object catch (error) {
      emit(state.copyWith(loading: false, error: '$error'));
    }
  }

  Future<void> save({
    required bool enabled,
    required String relayUrl,
    String? token,
    bool clearToken = false,
  }) async {
    emit(state.copyWith(saving: true, clearError: true));
    try {
      await _api.savePush(
        PushSettings(enabled: enabled, relayUrl: relayUrl),
        token: token,
        clearToken: clearToken,
      );
      final settings = await _api.pushSettings();
      emit(state.copyWith(settings: settings, saving: false, clearError: true));
    } on Object catch (error) {
      emit(state.copyWith(saving: false, error: '$error'));
      rethrow;
    }
  }

  Future<void> test() => _api.testPush();
}
