import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';

/// Какая операция с `mcp.json` сейчас выполняется.
enum McpBusyAction { import, export }

/// Состояние вкладки MCP в настройках.
class McpState extends Equatable {
  const McpState({
    this.servers = const [],
    this.states = const {},
    this.loading = false,
    this.busyAction,
    this.error,
    this.configError,
  });

  final List<McpServerConfig> servers;
  final Map<String, McpServerState> states;
  final bool loading;
  final String? error;
  final String? configError;

  /// Идёт ручной импорт или экспорт `mcp.json`.
  final McpBusyAction? busyAction;

  McpServerState stateOf(String serverId) =>
      states[serverId] ?? McpServerState.disconnected(serverId);

  McpState copyWith({
    List<McpServerConfig>? servers,
    Map<String, McpServerState>? states,
    bool? loading,
    McpBusyAction? busyAction,
    bool clearBusy = false,
    String? error,
    String? configError,
    bool clearError = false,
    bool clearConfigError = false,
  }) => McpState(
    servers: servers ?? this.servers,
    states: states ?? this.states,
    loading: loading ?? this.loading,
    busyAction: clearBusy ? null : (busyAction ?? this.busyAction),
    error: clearError ? null : (error ?? this.error),
    configError: clearConfigError ? null : (configError ?? this.configError),
  );

  @override
  List<Object?> get props => [
    servers,
    states,
    loading,
    busyAction,
    error,
    configError,
  ];
}

/// Загружает MCP-серверы профиля и управляет их подключениями из настроек.
class McpCubit extends Cubit<McpState> {
  McpCubit(this._api) : super(const McpState()) {
    _changes = _api.watchStates().listen(_onState);
  }

  final McpApi _api;
  late final StreamSubscription<McpServerState> _changes;

  Future<void> load() async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final snapshot = await _api.snapshot();
      emit(
        state.copyWith(
          servers: snapshot.servers,
          states: snapshot.states,
          loading: false,
          configError: snapshot.configError,
          clearError: true,
        ),
      );
      // Список уже виден: подключение серверов может занять время и не должно
      // задерживать первый кадр вкладки.
      await _api.ensureReady();
      await _reload();
    } on Object catch (error) {
      emit(state.copyWith(loading: false, error: '$error'));
    }
  }

  Future<void> save(McpServerConfig server) async {
    await _api.save(server);
    await _reload();
  }

  Future<void> delete(McpServerConfig server) async {
    await _api.delete(server);
    await _reload();
  }

  Future<void> toggle(McpServerConfig server, bool enabled) =>
      save(server.copyWith(enabled: enabled));

  Future<void> restart(McpServerConfig server) async {
    await _api.restart(server);
    await _reload();
  }

  Future<void> refreshTools(McpServerConfig server) async {
    await _api.refreshTools(server);
    await _reload();
  }

  Future<McpImportResult> importConfig() async {
    emit(state.copyWith(busyAction: McpBusyAction.import));
    try {
      final result = await _api.importConfig();
      await _reload();
      return result;
    } finally {
      emit(state.copyWith(clearBusy: true));
    }
  }

  Future<McpImportResult> importConfigText(
    String raw, {
    String? sourcePath,
  }) async {
    emit(state.copyWith(busyAction: McpBusyAction.import));
    try {
      final result = await _api.importConfigText(raw, sourcePath: sourcePath);
      await _reload();
      return result;
    } finally {
      emit(state.copyWith(clearBusy: true));
    }
  }

  /// Возвращает текст `mcp.json`. Файл на диск пишет экран: для удалённого
  /// профиля путь принадлежит клиенту, а конфигурация — серверу.
  Future<String> exportConfig() async {
    emit(state.copyWith(busyAction: McpBusyAction.export));
    try {
      return await _api.exportConfig();
    } finally {
      emit(state.copyWith(clearBusy: true));
    }
  }

  Future<void> _reload() async {
    final snapshot = await _api.snapshot();
    emit(
      state.copyWith(
        servers: snapshot.servers,
        states: snapshot.states,
        configError: snapshot.configError,
        clearError: true,
      ),
    );
  }

  void _onState(McpServerState update) {
    final states = Map<String, McpServerState>.of(state.states);
    states[update.serverId] = update;
    emit(state.copyWith(states: states));
  }

  @override
  Future<void> close() async {
    await _changes.cancel();
    return super.close();
  }
}
