import 'package:auto_route/auto_route.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/features/hosts/presentation/bloc/hosts_cubit.dart';
import 'package:probably_works/host/host_runtime_factory.dart';
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
        getIt<HostRuntimeFactory>(),
      ),
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.hostsTitle)),
        floatingActionButton: Builder(
          builder: (context) => FloatingActionButton.extended(
            heroTag: 'hosts-add-fab',
            icon: const Icon(Icons.add),
            label: Text(l10n.hostsAdd),
            onPressed: () => _openForm(context, null),
          ),
        ),
        body: BlocBuilder<HostsCubit, HostsState>(
          builder: (context, state) => ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final host in state.hosts)
                _HostCard(
                  host: host,
                  testing: state.testing.contains(host.id),
                  onTest: () => context.read<HostsCubit>().test(host),
                  onEdit: () => _openForm(context, host),
                  onDelete: () => _confirmDelete(context, host),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Host host) async {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<HostsCubit>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.hostDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok == true) await cubit.delete(host.id);
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
    final scheme = Theme.of(context).colorScheme;
    final failed = host.lastCheckError != null;
    return Card(
      child: ListTile(
        leading: Icon(host.isLocal ? Icons.computer : Icons.dns_outlined),
        title: Text(host.isLocal ? l10n.hostLocalName : host.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              host.isLocal
                  ? host.os.name
                  : '${host.username ?? ''}@${host.address ?? ''}:${host.port}',
            ),
            Text(
              _statusLine(host, l10n),
              style: TextStyle(color: failed ? scheme.error : null),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (host.notes != null && host.notes!.isNotEmpty)
              Text(host.notes!, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: l10n.hostTest,
              icon: testing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check),
              onPressed: testing ? null : onTest,
            ),
            IconButton(
              tooltip: l10n.messageEdit,
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
            if (!host.isLocal)
              IconButton(
                tooltip: l10n.commonDelete,
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
          ],
        ),
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
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}

/// Редактор Host. Для local — только рабочая папка, оболочка и заметки; для SSH — все поля подключения.
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
      keyPath: _local || _auth != SshAuthType.key
          ? null
          : orNull(_keyPath.text),
      hostKeyFingerprint: existing?.hostKeyFingerprint,
      os: existing?.os ?? HostOs.posix,
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
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_local) ...[
                TextField(
                  controller: _name,
                  decoration: InputDecoration(labelText: l10n.hostNameLabel),
                ),
                TextField(
                  controller: _address,
                  decoration: InputDecoration(
                    labelText: l10n.hostAddressLabel,
                    errorText: _addressError,
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: l10n.hostPortLabel,
                          errorText: _portError,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _user,
                        decoration: InputDecoration(
                          labelText: l10n.hostUserLabel,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<SshAuthType>(
                  segments: [
                    ButtonSegment(
                      value: SshAuthType.key,
                      label: Text(l10n.hostAuthKey),
                    ),
                    ButtonSegment(
                      value: SshAuthType.password,
                      label: Text(l10n.hostAuthPassword),
                    ),
                  ],
                  selected: {_auth},
                  onSelectionChanged: (value) =>
                      setState(() => _auth = value.first),
                ),
                const SizedBox(height: 12),
                if (_auth == SshAuthType.key)
                  TextField(
                    controller: _keyPath,
                    decoration: InputDecoration(
                      labelText: l10n.hostKeyPathLabel,
                    ),
                  ),
                TextField(
                  controller: _secret,
                  obscureText: true,
                  decoration: InputDecoration(labelText: l10n.hostSecretLabel),
                ),
              ],
              TextField(
                controller: _workspace,
                decoration: InputDecoration(
                  labelText: l10n.hostDefaultWorkspaceLabel,
                  suffixIcon: _local
                      ? IconButton(
                          tooltip: l10n.hostPickFolder,
                          icon: const Icon(Icons.folder_open),
                          onPressed: _pickFolder,
                        )
                      : null,
                ),
              ),
              TextField(
                controller: _shell,
                decoration: InputDecoration(
                  labelText: l10n.hostShellLabel,
                  helperText: l10n.hostShellHint,
                  errorText: _shellError,
                ),
              ),
              if (!_local)
                TextField(
                  controller: _timeout,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.hostTimeoutLabel,
                    errorText: _timeoutError,
                  ),
                ),
              TextField(
                controller: _notes,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(labelText: l10n.hostNotesLabel),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => _saveHost(l10n),
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
