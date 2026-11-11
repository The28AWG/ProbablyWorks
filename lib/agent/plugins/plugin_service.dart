import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:probably_works/agent/exec/command_executor.dart';
import 'package:probably_works/agent/plugins/plugin_catalog.dart';
import 'package:probably_works/agent/plugins/plugin_graph.dart';
import 'package:probably_works/agent/plugins/plugin_tool_source.dart';
import 'package:probably_works/agent/tools/tool_executor.dart';
import 'package:probably_works/core/data/settings_repository.dart';

/// Включение плагинов и регистрация их инструментов.
@lazySingleton
class PluginService {
  PluginService(this._catalog, this._settings, this._tools, this._commands);

  final PluginCatalog _catalog;
  final SettingsRepository _settings;
  final ToolExecutor _tools;
  final CommandExecutor _commands;

  static final _log = Logger('PluginService');
  static const _enabledPrefix = 'plugin.';
  static const _settingsPrefix = 'pluginSettings.';

  Future<void>? _ready;

  List<Plugin> get all => _catalog.plugins;

  Plugin? pluginById(String id) =>
      all.where((plugin) => plugin.id == id).firstOrNull;

  /// Включён ли плагин. Без сохранённого флага используется defaultEnabled.
  bool isEnabled(String id) {
    final plugin = pluginById(id);
    final raw = _settings.cached('$_enabledPrefix$id.enabled');
    if (raw == null) return plugin?.defaultEnabled ?? false;
    return raw == 'yes';
  }

  Set<String> get enabledIds => {
    for (final plugin in all)
      if (isEnabled(plugin.id)) plugin.id,
  };

  /// Все недостающие зависимости, включая транзитивные.
  Set<String> missingDependencies(String id, {Set<String>? enabled}) =>
      PluginGraph(all).missingDependencies(id, enabled ?? enabledIds);

  /// Включённые плагины, которые будут отключены вместе с [id].
  Set<String> dependents(String id, {Set<String>? enabled}) =>
      PluginGraph(all).dependents(id, enabled ?? enabledIds);

  Future<void> enable(Set<String> ids) => _setEnabled(ids, true);

  Future<void> disable(Set<String> ids) => _setEnabled(ids, false);

  Future<void> _setEnabled(Set<String> ids, bool value) async {
    for (final id in ids) {
      await _settings.write('$_enabledPrefix$id.enabled', value ? 'yes' : 'no');
    }
    await refresh();
  }

  /// Настройки плагина для его экрана и инструментов.
  PluginSettings settingsFor(String id) => _KvPluginSettings(this, id);

  Future<void> ensureReady() => _ready ??= _refresh();

  Future<void> refresh() {
    _ready = null;
    return ensureReady();
  }

  Future<void> _refresh() async {
    final enabled = enabledIds;
    for (final plugin in all) {
      _tools.unregisterToolSource(_sourceId(plugin.id));
    }
    for (final plugin in all) {
      if (!enabled.contains(plugin.id)) continue;
      try {
        final tools = await plugin.createTools(settingsFor(plugin.id));
        if (tools.isEmpty) continue;
        _tools.registerToolSource(
          PluginToolSource(plugin: plugin, tools: tools, commands: _commands),
        );
      } on Object catch (error) {
        _log.warning('cannot load plugin ${plugin.id}', error);
      }
    }
  }

  static String _sourceId(String pluginId) => 'plugin:$pluginId';
}

final class _KvPluginSettings implements PluginSettings {
  _KvPluginSettings(this._service, this._pluginId);

  final PluginService _service;
  final String _pluginId;

  String get _key => '${PluginService._settingsPrefix}$_pluginId';

  @override
  Future<Map<String, Object?>> read() async {
    final raw = await _service._settings.read(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      return json is Map ? Map<String, Object?>.from(json) : {};
    } on FormatException {
      return {};
    }
  }

  @override
  Future<void> save(Map<String, Object?> value) async {
    await _service._settings.write(_key, jsonEncode(value));
    await _service.refresh();
  }
}
