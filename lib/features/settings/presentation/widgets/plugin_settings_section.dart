import 'package:material_ui/material_ui.dart';
import 'package:plugin_api_ui/plugin_api_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';

PluginUi? _uiOf(String pluginId) => getIt<PluginUiRegistry>().byId(pluginId);

String _titleOf(BuildContext context, String pluginId) =>
    _uiOf(pluginId)?.titleOf(context) ?? pluginId;

/// Вкладка плагинов: включение, зависимости и настройки конкретного плагина.
class PluginSettingsSection extends StatefulWidget {
  const PluginSettingsSection({
    required this.api,
    required this.agentApi,
    super.key,
  });

  /// API профиля: локальный сервис или удалённый агент.
  final PluginApi api;

  /// Профиль нужен для подсказки до запроса; сервер повторно проверяет
  /// активные ходы и отвечает `409 agent_busy`.
  final AgentApi agentApi;

  @override
  State<PluginSettingsSection> createState() => _PluginSettingsSectionState();
}

class _PluginSettingsSectionState extends State<PluginSettingsSection> {
  var _loading = true;
  var _busy = false;
  var _enabled = <String>{};
  List<PluginDescriptor> _plugins = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await widget.api.pluginSnapshot();
      if (!mounted) return;
      setState(() {
        _plugins = snapshot.plugins;
        _enabled = snapshot.enabled;
        _loading = false;
      });
    } on Object {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(PluginDescriptor plugin, bool value) async {
    final l10n = AppLocalizations.of(context);
    if (widget.agentApi.runningChatIds.isNotEmpty) {
      AppSnackBar.show(context, l10n.pluginsRunning);
      return;
    }
    final affected = value
        ? await widget.api.missingDependencies(plugin.id)
        : await widget.api.dependents(plugin.id);
    if (!mounted) return;
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
    setState(() => _busy = true);
    try {
      await widget.api.setEnabled({plugin.id, ...affected}, enabled: value);
      await _load();
    } on AgentApiException catch (error) {
      if (!mounted) return;
      AppSnackBar.show(
        context,
        error.status == 409
            ? l10n.pluginsRunning
            : l10n.commonError(error.userMessage),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              busy: _busy,
              onToggle: (value) => _toggle(plugin, value),
              onSettings: _uiOf(plugin.id) == null
                  ? null
                  : () => _openSettings(plugin),
            ),
          ),
      ],
    );
  }

  Future<void> _openSettings(PluginDescriptor plugin) async {
    final settings = widget.api.settingsFor(plugin.id);
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
    await widget.api.refresh();
    await _load();
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.ui,
    required this.enabled,
    required this.busy,
    required this.onToggle,
    required this.onSettings,
  });

  final PluginDescriptor plugin;
  final PluginUi? ui;
  final bool enabled;
  final bool busy;
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
          Switch(value: enabled, onChanged: busy ? null : onToggle),
        ],
      ),
    );
  }
}
