import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/mcp/mcp_client_manager.dart';
import 'package:probably_works/agent/mcp/mcp_service.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/data/mcp_server_repository.dart';
import 'package:probably_works/core/domain/mcp_server.dart';
import 'package:probably_works/features/settings/presentation/bloc/mcp_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:uuid/uuid.dart';

/// Вкладка MCP в настройках: список серверов, их состояние и действия.
class McpSettingsSection extends StatefulWidget {
  const McpSettingsSection({super.key});

  @override
  State<McpSettingsSection> createState() => _McpSettingsSectionState();
}

class _McpSettingsSectionState extends State<McpSettingsSection> {
  late final McpCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = McpCubit(getIt<McpServerRepository>(), getIt<McpService>())
      ..load();
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocProvider.value(
      value: _cubit,
      child: BlocBuilder<McpCubit, McpState>(
        builder: (context, state) => AppSection(
          title: l10n.mcpServersTitle,
          description: l10n.mcpServersHint,
          trailing: IconButton(
            tooltip: l10n.mcpAddServer,
            icon: const Icon(Icons.add),
            onPressed: () => _edit(context, null),
          ),
          children: [
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _cubit.importConfig(),
                  icon: const Icon(Icons.file_download_outlined),
                  label: Text(l10n.mcpImportConfig),
                ),
                OutlinedButton.icon(
                  onPressed: () => _export(context),
                  icon: const Icon(Icons.file_upload_outlined),
                  label: Text(l10n.mcpExportConfig),
                ),
              ],
            ),
            if (state.configError case final error?)
              AppBanner(
                message: l10n.mcpConfigError(error),
                tone: AppTone.warning,
              ),
            if (state.error case final error?)
              AppBanner(message: l10n.commonError(error), tone: AppTone.danger),
            if (state.loading && state.servers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (state.servers.isEmpty)
              AppEmptyState(
                icon: Icons.cable_outlined,
                title: l10n.mcpEmptyTitle,
                message: l10n.mcpEmptyMessage,
              )
            else
              for (final server in state.servers)
                _ServerCard(
                  server: server,
                  state: state.stateOf(server.id),
                  onToggle: (enabled) => _cubit.toggle(server, enabled),
                  onRestart: () => _cubit.restart(server),
                  onRefresh: () => _cubit.refreshTools(server),
                  onEdit: server.isFileManaged
                      ? null
                      : () => _edit(context, server),
                  onDelete: server.isFileManaged
                      ? null
                      : () => _delete(context, server),
                  onTools: () => _showTools(context, server, state),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, McpServerConfig? server) async {
    final result = await showDialog<McpServerConfig>(
      context: context,
      builder: (_) => McpServerEditorDialog(server: server),
    );
    if (result == null || !mounted) return;
    await _cubit.save(result);
  }

  Future<void> _delete(BuildContext context, McpServerConfig server) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.mcpDeleteTitle,
      message: l10n.mcpDeleteConfirm(server.name),
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonDelete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _cubit.delete(server);
  }

  Future<void> _export(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      await _cubit.exportConfig();
      if (!context.mounted) return;
      AppSnackBar.show(context, l10n.mcpExportDone);
    } on Object catch (error) {
      if (!context.mounted) return;
      AppSnackBar.show(context, l10n.commonError('$error'));
    }
  }

  Future<void> _showTools(
    BuildContext context,
    McpServerConfig server,
    McpState state,
  ) => showDialog<void>(
    context: context,
    builder: (_) {
      final l10n = AppLocalizations.of(context);
      final tools = state.stateOf(server.id).tools;
      return AlertDialog(
        title: Text(
          l10n.mcpToolsTitle(server.name),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: SizedBox(
          width: AppLayout.dialogWidth,
          child: tools.isEmpty
              ? Text(l10n.mcpNoTools)
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final tool in tools)
                        AppCard(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                tool.displayName,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              if (tool.description case final description?)
                                Text(
                                  description,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.commonClose),
          ),
        ],
      );
    },
  );
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.state,
    required this.onToggle,
    required this.onRestart,
    required this.onRefresh,
    required this.onEdit,
    required this.onDelete,
    required this.onTools,
  });

  final McpServerConfig server;
  final McpServerState state;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRestart;
  final VoidCallback onRefresh;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback onTools;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tone = _tone(state.status);
    final colors = toneColors(context, tone);
    return AppCard(
      accent: colors.foreground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(
                tone: tone,
                pulse: state.status == McpConnectionStatus.connecting,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  server.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Text(
                _transportLabel(l10n, server.transport),
                style: theme.textTheme.labelSmall,
              ),
              if (server.isFileManaged) ...[
                const SizedBox(width: AppSpacing.sm),
                Tooltip(
                  message: l10n.mcpFileManaged,
                  child: const Icon(Icons.lock_outline, size: 16),
                ),
              ],
              const SizedBox(width: AppSpacing.sm),
              Switch(
                value: server.enabled,
                onChanged: server.isFileManaged ? null : onToggle,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _statusLabel(l10n, state),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.foreground,
            ),
          ),
          if (state.error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                l10n.mcpServerError(error),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Text(
                l10n.mcpToolsCount(state.tools.length),
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(width: AppSpacing.sm),
              TextButton.icon(
                onPressed: state.tools.isEmpty ? null : onTools,
                icon: const Icon(Icons.build_outlined, size: 16),
                label: Text(l10n.mcpViewTools),
              ),
              const Spacer(),
              IconButton(
                tooltip: l10n.mcpRestart,
                onPressed: onRestart,
                icon: const Icon(Icons.restart_alt),
              ),
              IconButton(
                tooltip: l10n.mcpRefreshTools,
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
              ),
              if (onEdit != null)
                IconButton(
                  tooltip: l10n.mcpEdit,
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
              if (onDelete != null)
                IconButton(
                  tooltip: l10n.commonDelete,
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static AppTone _tone(McpConnectionStatus status) => switch (status) {
    McpConnectionStatus.connected => AppTone.success,
    McpConnectionStatus.connecting => AppTone.progress,
    McpConnectionStatus.error => AppTone.danger,
    McpConnectionStatus.disconnected => AppTone.neutral,
  };

  static String _statusLabel(AppLocalizations l10n, McpServerState state) =>
      switch (state.status) {
        McpConnectionStatus.connected => l10n.mcpStatusConnected,
        McpConnectionStatus.connecting => l10n.mcpStatusConnecting,
        McpConnectionStatus.error => l10n.mcpStatusError,
        McpConnectionStatus.disconnected => l10n.mcpStatusDisconnected,
      };

  static String _transportLabel(
    AppLocalizations l10n,
    McpTransport transport,
  ) => switch (transport) {
    McpTransport.stdio => l10n.mcpTransportStdio,
    McpTransport.http => l10n.mcpTransportHttp,
  };
}

/// Диалог добавления и редактирования пользовательского MCP-сервера.
class McpServerEditorDialog extends StatefulWidget {
  const McpServerEditorDialog({this.server, super.key});

  final McpServerConfig? server;

  @override
  State<McpServerEditorDialog> createState() => _McpServerEditorDialogState();
}

class _McpServerEditorDialogState extends State<McpServerEditorDialog> {
  static const _uuid = Uuid();

  late final _name = TextEditingController(text: widget.server?.name ?? '');
  late final _command = TextEditingController(
    text: widget.server?.command ?? '',
  );
  late final _args = TextEditingController(
    text: widget.server?.args.join('\n') ?? '',
  );
  late final _cwd = TextEditingController(text: widget.server?.cwd ?? '');
  late final _url = TextEditingController(text: widget.server?.url ?? '');
  late final _env = TextEditingController(text: _pairsText(widget.server?.env));
  late final _headers = TextEditingController(
    text: _pairsText(widget.server?.headers),
  );
  late var _transport = widget.server?.transport ?? McpTransport.stdio;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _args.dispose();
    _cwd.dispose();
    _url.dispose();
    _env.dispose();
    _headers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final editing = widget.server != null;
    return AlertDialog(
      title: Text(
        editing ? l10n.mcpEditorEditTitle : l10n.mcpEditorAddTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: AppLayout.dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(
                controller: _name,
                label: l10n.mcpName,
                hint: l10n.mcpNameHint,
              ),
              const SizedBox(height: AppSpacing.md),
              AppChoiceGroup<McpTransport>(
                options: [
                  AppChoiceOption(
                    value: McpTransport.stdio,
                    title: l10n.mcpTransportStdio,
                    subtitle: l10n.mcpTransportStdioHint,
                    icon: const Icon(Icons.terminal_outlined),
                  ),
                  AppChoiceOption(
                    value: McpTransport.http,
                    title: l10n.mcpTransportHttp,
                    subtitle: l10n.mcpTransportHttpHint,
                    icon: const Icon(Icons.cloud_outlined),
                  ),
                ],
                selected: _transport,
                onChanged: (value) => setState(() => _transport = value),
              ),
              const SizedBox(height: AppSpacing.md),
              if (_transport == McpTransport.stdio) ...[
                AppTextField(
                  controller: _command,
                  label: l10n.mcpCommand,
                  hint: l10n.mcpCommandHint,
                  mono: true,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _args,
                  label: l10n.mcpArgs,
                  hint: l10n.mcpArgsHint,
                  minLines: 3,
                  maxLines: 5,
                  mono: true,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _cwd,
                  label: l10n.mcpCwd,
                  hint: l10n.mcpCwdHint,
                  mono: true,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _env,
                  label: l10n.mcpEnv,
                  hint: l10n.mcpEnvHint,
                  minLines: 3,
                  maxLines: 6,
                  mono: true,
                ),
              ] else ...[
                AppTextField(
                  controller: _url,
                  label: l10n.mcpUrl,
                  hint: l10n.mcpUrlHint,
                  keyboardType: TextInputType.url,
                  mono: true,
                ),
                const SizedBox(height: AppSpacing.md),
                AppTextField(
                  controller: _headers,
                  label: l10n.mcpHeaders,
                  hint: l10n.mcpHeadersHint,
                  minLines: 3,
                  maxLines: 6,
                  mono: true,
                ),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => _save(l10n),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }

  void _save(AppLocalizations l10n) {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.mcpInvalidName);
      return;
    }
    final command = _command.text.trim();
    final url = _url.text.trim();
    if (_transport == McpTransport.stdio && command.isEmpty) {
      setState(() => _error = l10n.mcpInvalidCommand);
      return;
    }
    if (_transport == McpTransport.http) {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
        setState(() => _error = l10n.mcpInvalidUrl);
        return;
      }
    }
    final now = DateTime.now();
    final server = McpServerConfig(
      id: widget.server?.id ?? _uuid.v4(),
      name: name,
      transport: _transport,
      source: McpServerSource.user,
      enabled: widget.server?.enabled ?? true,
      command: _transport == McpTransport.stdio ? command : null,
      args: _transport == McpTransport.stdio ? _lines(_args.text) : const [],
      env: _transport == McpTransport.stdio ? _pairs(_env.text) : const {},
      cwd: _transport == McpTransport.stdio && _cwd.text.trim().isNotEmpty
          ? _cwd.text.trim()
          : null,
      url: _transport == McpTransport.http ? url : null,
      headers: _transport == McpTransport.http
          ? _pairs(_headers.text)
          : const {},
      createdAt: widget.server?.createdAt ?? now,
      updatedAt: now,
    );
    Navigator.of(context).pop(server);
  }

  static List<String> _lines(String text) => [
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  static Map<String, String> _pairs(String text) {
    final result = <String, String>{};
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      final chars = trimmed.characters;
      final separator = chars.toList().indexWhere((char) => char == '=');
      if (separator <= 0) continue;
      result[chars.take(separator).toString().trim()] = chars
          .skip(separator + 1)
          .toString()
          .trim();
    }
    return result;
  }

  static String _pairsText(Map<String, String>? values) => values == null
      ? ''
      : [for (final entry in values.entries) '${entry.key}=${entry.value}']
            .join('\n');
}
