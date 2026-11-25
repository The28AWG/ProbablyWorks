import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/exec/command_executor.dart';
import 'package:pw_agent/agent/plugins/plugin_graph.dart';
import 'package:pw_agent/agent/plugins/plugin_registry.dart';
import 'package:pw_agent/agent/plugins/plugin_tool_source.dart';
import 'package:pw_agent/agent/state/domain_change_bus.dart';
import 'package:pw_agent/agent/state/shared_state.dart';
import 'package:pw_agent/agent/tools/tool_executor.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/security/secret_store.dart';

/// Включение плагинов и регистрация их инструментов.
@lazySingleton
class PluginService {
  PluginService(
    this._registry,
    this._settings,
    this._tools,
    this._commands,
    this._secrets, [
    this._changes,
  ]);

  final PluginRegistry _registry;
  final SettingsRepository _settings;
  final ToolExecutor _tools;
  final CommandExecutor _commands;
  final SecretStore _secrets;
  final DomainChangeBus? _changes;

  static final _log = Logger('PluginService');
  static const _enabledPrefix = 'plugin.';
  static const _settingsPrefix = 'pluginSettings.';
  static const _revisionKey = 'plugin.revision';

  /// Ревизия включённости и настроек плагинов.
  int get revision => int.tryParse(_settings.cached(_revisionKey) ?? '') ?? 0;

  /// Увеличивает ревизию. Вызывается после записи, чтобы открытая в другом
  /// окне форма не сохранила набор плагинов поверх изменений.
  Future<void> _bumpRevision() async {
    await _settings.write(_revisionKey, '${revision + 1}');
  }

  /// Сообщает окнам, что плагины изменились. Публикуется после записи, а не
  /// внутри транзакции: иначе окно успело бы прочитать старый снимок.
  void _notifyChanged() => _changes?.publish(SharedResource.plugins);

  Future<void>? _ready;

  List<Plugin> get all => _registry.plugins;

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

  Future<void> enable(Set<String> ids, {int? expectedRevision}) =>
      _setEnabled(ids, true, expectedRevision: expectedRevision);

  Future<void> disable(Set<String> ids, {int? expectedRevision}) =>
      _setEnabled(ids, false, expectedRevision: expectedRevision);

  Future<void> _setEnabled(
    Set<String> ids,
    bool value, {
    int? expectedRevision,
  }) async {
    // Проверка ревизии и записи флагов — одна транзакция: параллельное
    // переключение из другого окна не пройдёт между проверкой и записью.
    await _settings.transaction(() async {
      if (expectedRevision != null && expectedRevision != revision) {
        throw const AgentApiException(
          409,
          'plugin_conflict',
          'plugins were changed by another client',
        );
      }
      for (final id in ids) {
        await _settings.write(
          '$_enabledPrefix$id.enabled',
          value ? 'yes' : 'no',
        );
      }
      await _bumpRevision();
    });
    _notifyChanged();
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
          PluginToolSource(
            plugin: plugin,
            tools: tools,
            commands: _commands,
            files: _tools,
            secrets: _secrets,
          ),
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

  static final _secretName = RegExp(r'^[A-Za-z0-9._-]+$');

  final PluginService _service;
  final String _pluginId;

  String get _key => '${PluginService._settingsPrefix}$_pluginId';

  String _secretKey(String name) {
    if (!_secretName.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'invalid secret name');
    }
    return 'plugin.$_pluginId.secret.$name';
  }

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
    await _service._bumpRevision();
    _service._notifyChanged();
    await _service.refresh();
  }

  @override
  Future<bool> hasSecret(String name) async =>
      await _service._secrets.read(_secretKey(name)) != null;

  @override
  Future<void> writeSecret(String name, String? value) async {
    final key = _secretKey(name);
    if (value == null || value.isEmpty) {
      await _service._secrets.delete(key);
    } else {
      await _service._secrets.write(key, value);
    }
    await _service._bumpRevision();
    _service._notifyChanged();
    // Наличие ключа влияет на набор инструментов: без refresh search не
    // появится до следующего открытия настроек.
    await _service.refresh();
  }
}
