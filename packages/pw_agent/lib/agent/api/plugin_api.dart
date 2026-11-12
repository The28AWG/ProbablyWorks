import 'package:plugin_api/plugin_api.dart';

/// Описание ядра плагина для списка в настройках.
///
/// Названия и описания сюда не входят: это клиентское представление,
/// которое подбирается по [id] в `PluginUiRegistry`.
final class PluginDescriptor {
  const PluginDescriptor({
    required this.id,
    required this.dependsOn,
    required this.defaultEnabled,
  });

  final String id;
  final Set<String> dependsOn;
  final bool defaultEnabled;
}

/// Снимок ядра плагинов и их флагов включения.
final class PluginSnapshot {
  const PluginSnapshot({required this.plugins, required this.enabled});

  final List<PluginDescriptor> plugins;
  final Set<String> enabled;
}

/// Управление ядром плагинов конкретного агента.
///
/// [setEnabled] обязан завершиться ошибкой `409 agent_busy`, если хотя бы один
/// ход агента ещё выполняется: набор инструментов нельзя менять посреди хода.
abstract interface class PluginApi {
  Future<PluginSnapshot> pluginSnapshot();

  Future<Set<String>> missingDependencies(String id);
  Future<Set<String>> dependents(String id);

  Future<void> setEnabled(Set<String> ids, {required bool enabled});

  /// Настройки плагина. Для удалённого профиля чтение и запись идут через API.
  PluginSettings settingsFor(String id);

  Future<void> refresh();
}

/// JSON-представление ядра плагина.
Map<String, Object?> pluginDescriptorToJson(PluginDescriptor plugin) => {
  'id': plugin.id,
  'dependsOn': plugin.dependsOn.toList()..sort(),
  'defaultEnabled': plugin.defaultEnabled,
};

/// Восстанавливает описание ядра из JSON API.
PluginDescriptor pluginDescriptorFromJson(Map<String, dynamic> json) =>
    PluginDescriptor(
      id: '${json['id'] ?? ''}',
      dependsOn: {
        for (final id in (json['dependsOn'] as List? ?? const []))
          if (id is String) id,
      },
      defaultEnabled: json['defaultEnabled'] == true,
    );

/// JSON-представление снимка ядра плагинов.
Map<String, Object?> pluginSnapshotToJson(PluginSnapshot snapshot) => {
  'plugins': [
    for (final plugin in snapshot.plugins) pluginDescriptorToJson(plugin),
  ],
  'enabled': snapshot.enabled.toList()..sort(),
};

/// Восстанавливает снимок ядра из JSON API.
PluginSnapshot pluginSnapshotFromJson(Map<String, dynamic> json) =>
    PluginSnapshot(
      plugins: [
        for (final item in (json['plugins'] as List? ?? const []))
          if (item is Map)
            pluginDescriptorFromJson(Map<String, dynamic>.from(item)),
      ],
      enabled: {
        for (final id in (json['enabled'] as List? ?? const []))
          if (id is String) id,
      },
    );
