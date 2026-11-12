import 'package:material_ui/material_ui.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_api_ui/plugin_api_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/plugins/plugin_service.dart';

PluginUi? _uiOf(String pluginId) => getIt<PluginUiRegistry>().byId(pluginId);

String _titleOf(BuildContext context, String pluginId) =>
    _uiOf(pluginId)?.titleOf(context) ?? pluginId;

/// Вкладка плагинов: включение, зависимости и настройки конкретного плагина.
class PluginSettingsSection extends StatefulWidget {
  const PluginSettingsSection({super.key});

  @override
  State<PluginSettingsSection> createState() => _PluginSettingsSectionState();
}

class _PluginSettingsSectionState extends State<PluginSettingsSection> {
  final _service = getIt<PluginService>();
  var _loading = true;
  var _enabled = <String>{};
  List<Plugin> _plugins = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final plugins = _service.all;
    final enabled = _service.enabledIds;
    if (!mounted) return;
    setState(() {
      _plugins = plugins;
      _enabled = enabled;
      _loading = false;
    });
  }

  Future<void> _toggle(Plugin plugin, bool value) async {
    final l10n = AppLocalizations.of(context);
    if (getIt<AgentApi>().runningChatIds.isNotEmpty) {
      AppSnackBar.show(context, l10n.pluginsRunning);
      return;
    }
    final affected = value
        ? _service.missingDependencies(plugin.id)
        : _service.dependents(plugin.id);
    if (affected.isNotEmpty) {
      final names = [for (final id in affected) _titleOf(context, id)];
      final confirmed = await ConfirmDialog.confirm(
        context,
        title: value ? l10n.pluginsMissingTitle : l10n.pluginsDependentsTitle,
        message: value
            ? l10n.pluginsMissingMessage(names.join(', '))
            : l10n.pluginsDependentsMessage(names.join(', ')),
        cancelLabel: l10n.commonCancel,
        confirmLabel: value ? l10n.pluginsEnableAll : l10n.pluginsDisableAll,
      );
      if (!confirmed || !mounted) return;
    }
    final ids = {plugin.id, ...affected};
    if (value) {
      await _service.enable(ids);
    } else {
      await _service.disable(ids);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final plugin in _plugins)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: _PluginCard(
              plugin: plugin,
              ui: _uiOf(plugin.id),
              enabled: _enabled.contains(plugin.id),
              onToggle: (value) => _toggle(plugin, value),
              onSettings: _uiOf(plugin.id) == null
                  ? null
                  : () => _openSettings(plugin),
            ),
          ),
      ],
    );
  }

  Future<void> _openSettings(Plugin plugin) async {
    final settings = _service.settingsFor(plugin.id);
    final child = _uiOf(plugin.id)?.buildSettings(context, settings);
    if (child == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          _titleOf(context, plugin.id),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: AppLayout.dialogWidth,
          child: SingleChildScrollView(child: child),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(AppLocalizations.of(context).commonClose),
          ),
        ],
      ),
    );
    await _service.refresh();
    await _load();
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.ui,
    required this.enabled,
    required this.onToggle,
    required this.onSettings,
  });

  final Plugin plugin;
  final PluginUi? ui;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dependencies = [
      for (final id in plugin.dependsOn) _titleOf(context, id),
    ];
    return AppCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ui?.titleOf(context) ?? plugin.id,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  ui?.descriptionOf(context) ?? '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (dependencies.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    l10n.pluginDependsOn(dependencies.join(', ')),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ],
            ),
          ),
          if (onSettings != null)
            IconButton(
              tooltip: l10n.pluginSettings,
              onPressed: onSettings,
              icon: const Icon(Icons.tune),
            ),
          Switch(value: enabled, onChanged: onToggle),
        ],
      ),
    );
  }
}
