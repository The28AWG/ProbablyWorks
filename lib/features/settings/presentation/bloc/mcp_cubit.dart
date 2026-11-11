import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/core/data/mcp_server_repository.dart';
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

/// Загружает MCP-серверы и управляет их подключениями из настроек.
class McpCubit extends Cubit<McpState> {
  McpCubit(this._repository, this._service) : super(const McpState()) {
    _changes = _service.changes.listen(_onState);
  }

  final McpServerRepository _repository;
  final McpService _service;
  late final StreamSubscription<McpServerState> _changes;

  Future<void> load() async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final servers = await _repository.all();
      emit(
        state.copyWith(
          servers: servers,
          states: {
            for (final server in servers)
              server.id: _service.stateOf(server.id),
          },
          loading: false,
          configError: _service.configError,
        ),
      );
      await _service.ensureReady();
      await _reloadStates();
    } on Object catch (error) {
      emit(state.copyWith(loading: false, error: '$error'));
    }
  }

  Future<void> save(McpServerConfig server) async {
    final now = DateTime.now();
    final updated = server.copyWith(updatedAt: now);
    await _repository.upsert(updated);
    if (updated.enabled) {
      await _service.restart(updated);
    } else {
      await _service.disconnect(updated);
    }
    await _reloadStates();
  }

  Future<void> delete(McpServerConfig server) async {
    await _repository.delete(server.id);
    await _service.disconnect(server);
    await _reloadStates();
  }

  Future<void> toggle(McpServerConfig server, bool enabled) =>
      save(server.copyWith(enabled: enabled));

  Future<void> restart(McpServerConfig server) async {
    await _service.restart(server);
    await _reloadStates();
  }

  Future<void> refreshTools(McpServerConfig server) async {
    await _service.refreshServer(server);
    await _reloadStates();
  }

  Future<McpImportResult> importConfig() async {
    emit(state.copyWith(busyAction: McpBusyAction.import));
    try {
      final result = await _service.importConfig();
      await _reloadStates();
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
      final result = await _service.importConfigText(
        raw,
        sourcePath: sourcePath,
      );
      await _reloadStates();
      return result;
    } finally {
      emit(state.copyWith(clearBusy: true));
    }
  }

  Future<String> exportConfig() async {
    emit(state.copyWith(busyAction: McpBusyAction.export));
    try {
      return await _service.exportConfig();
    } finally {
      emit(state.copyWith(clearBusy: true));
    }
  }

  Future<String> exportConfigTo(String path) async {
    emit(state.copyWith(busyAction: McpBusyAction.export));
    try {
      return await _service.exportConfigTo(path);
    } finally {
      emit(state.copyWith(clearBusy: true));
    }
  }

  Future<void> _reloadStates() async {
    final servers = await _repository.all();
    emit(
      state.copyWith(
        servers: servers,
        states: {
          for (final server in servers) server.id: _service.stateOf(server.id),
        },
        configError: _service.configError,
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
