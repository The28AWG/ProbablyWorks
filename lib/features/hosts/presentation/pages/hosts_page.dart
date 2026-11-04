import 'package:auto_route/auto_route.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/local_host_presentation.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/features/hosts/presentation/bloc/hosts_cubit.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';
import 'package:probably_works/host/host_diagnostics.dart';
import 'package:probably_works/host/process_control.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:uuid/uuid.dart';

@RoutePage()
class HostsPage extends StatelessWidget {
  const HostsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocProvider(
      create: (_) => HostsCubit(
        getIt<HostRepository>(),
        getIt<SecretStore>(),
        getIt<HostDiagnostics>(),
      ),
      child: AppScaffold(
        appBar: AppBar(
          leading: context.workspaceLayout == .compact
              ? const WorkspaceLeadingButton()
              : null,
          title: Text(
            l10n.hostsTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        maxWidth: AppLayout.pageMaxWidth,
        floatingActionButton: Builder(
          builder: (context) => FloatingActionButton.extended(
            heroTag: 'hosts-add-fab',
            icon: const Icon(Icons.add),
            label: Text(
              l10n.hostsAdd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => _openForm(context, null),
          ),
        ),
        body: BlocBuilder<HostsCubit, HostsState>(
          builder: (context, state) {
            if (state.hosts.isEmpty) {
              return AppEmptyState(
                icon: Icons.dns_outlined,
                title: l10n.hostsAdd,
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                96,
              ),
              children: [
                for (final host in state.hosts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _HostCard(
                      host: host,
                      testing: state.testing.contains(host.id),
                      onTest: () => context.read<HostsCubit>().test(host),
                      onEdit: () => _openForm(context, host),
                      onDelete: () => _confirmDelete(context, host),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Host host) async {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<HostsCubit>();
    final ok = await ConfirmDialog.confirm(
      context,
      title: l10n.commonDelete,
      message: l10n.hostDeleteConfirm,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonDelete,
      destructive: true,
    );
    if (ok) await cubit.delete(host.id);
  }

  Future<void> _openForm(BuildContext context, Host? existing) async {
    final cubit = context.read<HostsCubit>();
    await showDialog<void>(
      context: context,
      builder: (_) => BlocProvider.value(
        value: cubit,
        child: _HostForm(existing: existing),
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.testing,
    required this.onTest,
    required this.onEdit,
    required this.onDelete,
  });

  final Host host;
  final bool testing;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = host.lastCheckError != null;
    final checked = host.lastCheckAt != null;
    final (tone, statusLabel) = failed
        ? (AppTone.danger, l10n.hostStatusFailed)
        : checked
        ? (AppTone.success, l10n.hostStatusOnline)
        : (AppTone.neutral, l10n.hostStatusUnknown);
    final address = host.isLocal
        ? host.os.name
        : '${host.username ?? ''}@${host.address ?? ''}:${host.port}';
    final name = host.isLocal ? localHostTitle(l10n) : host.name;
    final notes = host.notes;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: AppRadius.mdAll,
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Icon(
                host.isLocal ? localHostIcon() : Icons.dns_outlined,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    StatusChip(label: statusLabel, tone: tone),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.monoFamily,
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _statusLine(host, l10n),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: failed ? scheme.error : scheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (notes != null && notes.isNotEmpty)
                  Text(
                    notes,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton.outlined(
            tooltip: l10n.hostTest,
            icon: testing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check),
            onPressed: testing ? null : onTest,
          ),
          PopupMenuButton<String>(
            tooltip: l10n.commonMore,
            onSelected: (action) => action == 'edit' ? onEdit() : onDelete(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'edit',
                child: Text(
                  l10n.messageEdit,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!host.isLocal)
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    l10n.commonDelete,
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _statusLine(Host host, AppLocalizations l10n) {
    final at = host.lastCheckAt;
    if (at == null) return l10n.hostNeverChecked;
    final time = _formatTime(at);
    final error = host.lastCheckError;
    if (error != null) {
      return l10n.hostLastCheckFailed(
        time,
        TextClip.headTail(error, maxChars: 200),
      );
    }
    return l10n.hostLastCheckOk(time, host.lastLatencyMs ?? 0);
  }

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

/// Редактор Host. Для local — только окружение; для SSH — подключение, аутентификация и окружение.
class _HostForm extends StatefulWidget {
  const _HostForm({this.existing});

  final Host? existing;

  @override
  State<_HostForm> createState() => _HostFormState();
}

class _HostFormState extends State<_HostForm> {
  late final _local = widget.existing?.isLocal ?? false;
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _address = TextEditingController(
    text: widget.existing?.address ?? '',
  );
  late final _port = TextEditingController(
    text: '${widget.existing?.port ?? 22}',
  );
  late final _user = TextEditingController(
    text: widget.existing?.username ?? '',
  );
  late final _keyPath = TextEditingController(
    text: widget.existing?.keyPath ?? '',
  );
  final _privateKey = TextEditingController();
  late HostOs _os = switch (widget.existing?.os) {
    HostOs.macos => HostOs.macos,
    HostOs.windows => HostOs.windows,
    _ => HostOs.posix,
  };
  late final _workspace = TextEditingController(
    text: widget.existing?.defaultWorkspace ?? '',
  );
  late final _shell = TextEditingController(
    text: widget.existing?.shellOverride ?? '',
  );
  late final _timeout = TextEditingController(
    text: widget.existing?.connectTimeoutSeconds?.toString() ?? '',
  );
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  final _secret = TextEditingController();
  late SshAuthType _auth = widget.existing?.authType ?? SshAuthType.key;

  String? _addressError;
  String? _portError;
  String? _timeoutError;
  String? _shellError;

  @override
  void dispose() {
    for (final c in [
      _name,
      _address,
      _port,
      _user,
      _keyPath,
      _privateKey,
      _workspace,
      _shell,
      _timeout,
      _notes,
      _secret,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath();
    if (!mounted) return;
    if (path != null) setState(() => _workspace.text = path);
  }

  /// Читает PEM из выбранного файла в поле. Путь сохраняется только как подпись: PEM уходит в secure storage.
  Future<void> _pickKeyFile() async {
    final file = await openFile();
    if (!mounted || file == null) return;
    final pem = await file.readAsString();
    if (!mounted) return;
    setState(() {
      _privateKey.text = pem;
      if (AppPlatform.current.canOpenExternalKeys) _keyPath.text = file.path;
    });
  }

  /// Проверяет поля; возвращает true, если можно сохранять.
  bool _validate(AppLocalizations l10n) {
    final port = int.tryParse(_port.text.trim());
    final timeoutText = _timeout.text.trim();
    final timeout = int.tryParse(timeoutText);
    final shell = _shell.text.trim();
    setState(() {
      _addressError = !_local && _address.text.trim().isEmpty
          ? l10n.hostAddressRequired
          : null;
      _portError = !_local && (port == null || port < 1 || port > 65535)
          ? l10n.hostPortInvalid
          : null;
      _timeoutError =
          !_local && timeoutText.isNotEmpty && (timeout == null || timeout <= 0)
          ? l10n.hostTimeoutInvalid
          : null;
      _shellError = shell.isNotEmpty && !ProcessControl.isValidShell(shell)
          ? l10n.hostShellInvalid
          : null;
    });
    return _addressError == null &&
        _portError == null &&
        _timeoutError == null &&
        _shellError == null;
  }

  Future<void> _saveHost(AppLocalizations l10n) async {
    if (!_validate(l10n)) return;
    final host = _build();
    await context.read<HostsCubit>().save(
      host,
      secret: _local ? null : _secret.text,
      privateKeyPem: _local || _auth != SshAuthType.key
          ? null
          : _privateKey.text,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  Host _build() {
    final existing = widget.existing;
    final now = DateTime.now();
    String? orNull(String value) => value.trim().isEmpty ? null : value.trim();
    final name = _name.text.trim().isEmpty
        ? _address.text.trim()
        : _name.text.trim();
    return Host(
      id: existing?.id ?? const Uuid().v4(),
      name: _local ? existing!.name : name,
      kind: existing?.kind ?? HostKind.ssh,
      address: _local ? null : _address.text.trim(),
      port: _local ? (existing?.port ?? 22) : int.parse(_port.text.trim()),
      username: _local ? null : orNull(_user.text),
      authType: _auth,
      keyPath:
          _local ||
              _auth != SshAuthType.key ||
              !AppPlatform.current.canOpenExternalKeys
          ? null
          : orNull(_keyPath.text),
      hostKeyFingerprint: existing?.hostKeyFingerprint,
      os: _local ? (existing?.os ?? HostOs.posix) : _os,
      defaultWorkspace: orNull(_workspace.text),
      shellOverride: orNull(_shell.text),
      notes: orNull(_notes.text),
      connectTimeoutSeconds: _local ? null : int.tryParse(_timeout.text.trim()),
      lastCheckAt: existing?.lastCheckAt,
      lastLatencyMs: existing?.lastLatencyMs,
      lastCheckError: existing?.lastCheckError,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        _local
            ? l10n.hostLocalSettingsTitle
            : (widget.existing == null ? l10n.hostsAdd : l10n.navHosts),
      ),
      content: SizedBox(
        width: AppLayout.dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_local) ...[
                AppSection(
                  title: l10n.hostFormSectionConnection,
                  children: [
                    AppTextField(controller: _name, label: l10n.hostNameLabel),
                    AppTextField(
                      controller: _address,
                      label: l10n.hostAddressLabel,
                      error: _addressError,
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: AppTextField(
                            controller: _port,
                            label: l10n.hostPortLabel,
                            error: _portError,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          flex: 2,
                          child: AppTextField(
                            controller: _user,
                            label: l10n.hostUserLabel,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      l10n.hostOsLabel,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    SegmentedButton<HostOs>(
                      segments: [
                        ButtonSegment(
                          value: HostOs.posix,
                          label: Text(
                            l10n.hostOsPosix,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        ButtonSegment(
                          value: HostOs.macos,
                          label: Text(
                            l10n.hostOsMacos,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        ButtonSegment(
                          value: HostOs.windows,
                          label: Text(
                            l10n.hostOsWindows,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      selected: {_os},
                      onSelectionChanged: (value) =>
                          setState(() => _os = value.first),
                    ),
                  ],
                ),
                AppSection(
                  title: l10n.hostFormSectionAuth,
                  children: [
                    SegmentedButton<SshAuthType>(
                      segments: [
                        ButtonSegment(
                          value: SshAuthType.key,
                          label: Text(
                            l10n.hostAuthKey,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        ButtonSegment(
                          value: SshAuthType.password,
                          label: Text(
                            l10n.hostAuthPassword,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      selected: {_auth},
                      onSelectionChanged: (value) =>
                          setState(() => _auth = value.first),
                    ),
                    if (_auth == SshAuthType.key) ...[
                      OutlinedButton.icon(
                        onPressed: _pickKeyFile,
                        icon: const Icon(Icons.key_outlined),
                        label: Text(
                          l10n.hostPickKeyFile,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_keyPath.text.isNotEmpty)
                        Text(
                          _keyPath.text,
                          style: Theme.of(context).textTheme.labelSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      AppTextField(
                        controller: _privateKey,
                        label: l10n.hostPrivateKeyLabel,
                        helper: l10n.hostPrivateKeyHint,
                        mono: true,
                        minLines: 3,
                        maxLines: 8,
                      ),
                    ],
                    AppTextField(
                      controller: _secret,
                      label: l10n.hostSecretLabel,
                      obscure: true,
                    ),
                  ],
                ),
              ],
              AppSection(
                title: l10n.hostFormSectionEnvironment,
                children: [
                  AppTextField(
                    controller: _workspace,
                    label: l10n.hostDefaultWorkspaceLabel,
                    mono: true,
                    suffix:
                        _local && AppPlatform.current.supportsDirectoryPicker
                        ? IconButton(
                            tooltip: l10n.hostPickFolder,
                            icon: const Icon(Icons.folder_open),
                            onPressed: _pickFolder,
                          )
                        : null,
                  ),
                  AppTextField(
                    controller: _shell,
                    label: l10n.hostShellLabel,
                    helper: l10n.hostShellHint,
                    error: _shellError,
                    mono: true,
                  ),
                  if (!_local)
                    AppTextField(
                      controller: _timeout,
                      label: l10n.hostTimeoutLabel,
                      error: _timeoutError,
                      keyboardType: TextInputType.number,
                    ),
                  AppTextField(
                    controller: _notes,
                    label: l10n.hostNotesLabel,
                    minLines: 2,
                    maxLines: 4,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            l10n.commonCancel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        FilledButton(
          onPressed: () => _saveHost(l10n),
          child: Text(
            l10n.commonSave,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
