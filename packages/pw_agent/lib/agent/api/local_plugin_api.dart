import 'package:injectable/injectable.dart';
import 'package:plugin_api/plugin_api.dart' as plugins;
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/plugins/plugin_service.dart';
import 'package:pw_agent/src/agent/loop/agent_hub.dart';

/// Локальное управление плагинами поверх [PluginService].
@LazySingleton(as: PluginApi)
final class LocalPluginApi implements PluginApi {
  LocalPluginApi(this._service, this._hub);

  final PluginService _service;
  final AgentHub _hub;

  @override
  Future<PluginSnapshot> pluginSnapshot() async => PluginSnapshot(
    plugins: [
      for (final plugin in _service.all)
        PluginDescriptor(
          id: plugin.id,
          dependsOn: plugin.dependsOn,
          defaultEnabled: plugin.defaultEnabled,
        ),
    ],
    enabled: _service.enabledIds,
  );

  @override
  Future<Set<String>> missingDependencies(String id) async =>
      _service.missingDependencies(id);

  @override
  Future<Set<String>> dependents(String id) async => _service.dependents(id);

  @override
  Future<void> setEnabled(Set<String> ids, {required bool enabled}) async {
    if (_hub.runningChatIds.isNotEmpty) {
      throw const AgentApiException(
        409,
        'agent_busy',
        'cannot change plugins while the agent is running',
      );
    }
    if (enabled) {
      await _service.enable(ids);
    } else {
      await _service.disable(ids);
    }
  }

  @override
  plugins.PluginSettings settingsFor(String id) => _service.settingsFor(id);

  @override
  Future<void> refresh() => _service.refresh();
}
