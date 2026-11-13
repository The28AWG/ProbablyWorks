import 'dart:async';
import 'dart:io';

import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:pw_agent/agent/mcp/mcp_client_manager.dart';
import 'package:pw_agent/agent/mcp/mcp_config_file.dart';
import 'package:pw_agent/agent/mcp/mcp_tool_source.dart';
import 'package:pw_agent/agent/tools/tool_executor.dart';
import 'package:pw_agent/core/data/mcp_server_repository.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/security/secret_store.dart';

export 'package:pw_agent/agent/mcp/mcp_types.dart';

/// Связывает настройки MCP, подключения и общий реестр инструментов.
///
/// Серверы подключаются лениво: [ensureReady] вызывается перед первым запросом
/// к модели, а настройки могут перечитать список через [refresh].
@lazySingleton
class McpService {
  McpService(this._repository, this._manager, this._tools, this._secrets);

  final McpServerRepository _repository;
  final McpClientManager _manager;
  final ToolExecutor _tools;
  final SecretStore _secrets;

  static final _log = Logger('McpService');

  McpConfigFile? _configFile;
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _debounce;
  Future<void>? _ready;
  final _knownServers = <String>{};
  var _suppressWatch = false;
  String? _configError;

  /// Ошибка последнего импорта `mcp.json`, если она была.
  String? get configError => _configError;

  /// Путь к файлу конфигурации, если сервис его знает.
  String? get configFilePath => _configFile?.file.path;

  /// Импортирует `mcp.json` и начинает следить за файлом.
  ///
  /// Подключение серверов не запускается здесь: иначе старт приложения ждал бы
  /// сеть и дочерние процессы. Это делает [ensureReady] перед первым запросом.
  Future<void> start({File? configFile}) async {
    if (configFile == null) return;
    _configFile = McpConfigFile(configFile, _repository, _secrets);
    await _importConfig();
    _watchFile(configFile);
  }

  /// Гарантирует, что включённые серверы подключены, а их инструменты зарегистрированы.
  Future<void> ensureReady() => _ready ??= _refresh();

  /// Перечитывает настройки и пересобирает источники инструментов.
  Future<void> refresh() {
    _ready = null;
    return ensureReady();
  }

  /// Состояние сервера для настроек.
  McpServerState stateOf(String serverId) => _manager.stateOf(serverId);

  /// Поток изменений состояния подключений.
  Stream<McpServerState> get changes => _manager.changes;

  /// Перезапускает сервер и обновляет его источник инструментов.
  Future<McpServerState> restart(McpServerConfig server) async {
    final state = await _manager.restart(server);
    await _replaceSource(server, state);
    return state;
  }

  /// Перечитывает `tools/list` без пересоздания подключения.
  Future<McpServerState> refreshServer(McpServerConfig server) async {
    final state = await _manager.refreshTools(server);
    await _replaceSource(server, state);
    return state;
  }

  /// Отключает сервер и убирает его инструменты из реестра.
  Future<void> disconnect(McpServerConfig server) async {
    _tools.unregisterToolSource(_sourceId(server));
    _knownServers.remove(server.id);
    await _manager.disconnect(server.id);
  }

  /// Перечитывает `mcp.json` по запросу пользователя и обновляет подключения.
  Future<McpImportResult> importConfig() async {
    final file = _configFile;
    if (file == null) return const McpImportResult.missing(null);
    final path = file.file.path;
    if (!file.file.existsSync()) {
      _configError = null;
      return McpImportResult.missing(path);
    }
    await _importConfig();
    if (_configError case final error?) {
      return McpImportResult.error(error, path);
    }
    await refresh();
    return McpImportResult.imported(path);
  }

  /// Импортирует текст, выбранный пользователем через файловый диалог.
  Future<McpImportResult> importConfigText(
    String raw, {
    String? sourcePath,
  }) async {
    final file = _configFile;
    if (file == null) {
      return const McpImportResult.error(
        'MCP config file is not configured',
        null,
      );
    }
    try {
      await file.importRaw(raw);
      _configError = null;
    } on Object catch (error) {
      _configError = '$error';
      _log.warning('cannot import selected mcp.json', error);
      return McpImportResult.error('$error', sourcePath);
    }
    await refresh();
    return McpImportResult.imported(sourcePath);
  }

  /// Экспортирует текущие настройки в `mcp.json` и возвращает путь.
  Future<String> exportConfig() async {
    final file = _configFile;
    if (file == null) {
      throw StateError('MCP config file is not configured');
    }
    return exportConfigTo(file.file.path);
  }

  /// Экспортирует текущие настройки в выбранный пользователем файл.
  Future<String> exportConfigTo(String path) async {
    final file = _configFile;
    if (file == null) {
      throw StateError('MCP config file is not configured');
    }
    _suppressWatch = true;
    try {
      return await file.exportTo(File(path));
    } finally {
      _suppressWatch = false;
    }
  }

  Future<void> _refresh() async {
    final servers = await _repository.all();
    final ids = {for (final server in servers) server.id};
    for (final id in [..._knownServers]) {
      if (ids.contains(id)) continue;
      _tools.unregisterToolSource('mcp:$id');
      _knownServers.remove(id);
      await _manager.disconnect(id);
    }
    for (final server in servers) {
      _knownServers.add(server.id);
      if (!server.enabled) {
        _tools.unregisterToolSource(_sourceId(server));
        await _manager.disconnect(server.id);
        continue;
      }
      final state = await _manager.connect(server);
      await _replaceSource(server, state);
    }
  }

  Future<void> _replaceSource(
    McpServerConfig server,
    McpServerState state,
  ) async {
    _tools.unregisterToolSource(_sourceId(server));
    if (!state.isConnected) return;
    try {
      _tools.registerToolSource(
        McpToolSource(server: server, manager: _manager, tools: state.tools),
      );
    } on Object catch (error) {
      _log.warning('cannot register MCP tools for ${server.name}', error);
    }
  }

  Future<void> _importConfig() async {
    final file = _configFile;
    if (file == null) return;
    try {
      await file.import();
      _configError = null;
    } on Object catch (error) {
      _configError = '$error';
      _log.warning('cannot import mcp.json', error);
    }
  }

  void _watchFile(File file) {
    final parent = file.parent;
    if (!parent.existsSync()) return;
    try {
      _watch = parent.watch().listen((event) {
        if (event.path != file.path) return;
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 300), () {
          if (_suppressWatch) return;
          unawaited(() async {
            await _importConfig();
            if (_configError == null) await refresh();
          }());
        });
      });
    } on Object catch (error) {
      _log.fine('MCP file watch is unavailable', error);
    }
  }

  static String _sourceId(McpServerConfig server) => 'mcp:${server.id}';

  /// Останавливает наблюдение за файлом и закрывает подключения.
  Future<void> dispose() async {
    _debounce?.cancel();
    await _watch?.cancel();
    await _manager.closeAll();
  }
}
