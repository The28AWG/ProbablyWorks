import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/features/hosts/presentation/bloc/hosts_cubit.dart';
import 'package:probably_works/features/settings/presentation/widgets/settings_form_row.dart';
import 'package:probably_works/host/process_control.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:uuid/uuid.dart';

/// Сохранение хоста: форма не знает о кубите, поэтому её можно проверять без DI.
typedef HostSave = Future<void> Function(
  Host host, {
  String? secret,
  String? privateKeyPem,
});

/// Значки систем — собственные SVG в одной сетке 24×24, чтобы их визуальный размер совпадал.
/// Material не даёт узнаваемых логотипов Linux, macOS и Windows: ноутбук одинаков для всех.
const _linuxIconAsset = 'assets/icons/os_linux.svg';
const _macosIconAsset = 'assets/icons/os_macos.svg';
const _windowsIconAsset = 'assets/icons/os_windows.svg';

/// Открывает редактор хоста. [existing] null — новый SSH-хост; для локального хоста
/// редактируется только окружение. Сохранение идёт через [HostsCubit], который должен быть в контексте.
Future<void> showHostFormDialog(BuildContext context, {Host? existing}) {
  final cubit = context.read<HostsCubit>();
  return showDialog<void>(
    context: context,
    builder: (_) => HostFormDialog(existing: existing, onSave: cubit.save),
  );
}

/// Диалог «Хост»: подключение, аутентификация и окружение SSH-хоста. Строки формы — как в настройках:
/// название и пояснение слева, поле справа; подписей над полями нет. Ширина до
/// `AppLayout.formMaxWidth`, на узком экране строки складываются сами.
class HostFormDialog extends StatefulWidget {
  const HostFormDialog({required this.onSave, this.existing, super.key});

  /// Редактируемый хост. Null — новый SSH-хост.
  final Host? existing;

  /// Сохраняет хост и секреты (пароль, passphrase, PEM).
  final HostSave onSave;

  @override
  State<HostFormDialog> createState() => _HostFormDialogState();
}

class _HostFormDialogState extends State<HostFormDialog> {
  /// Отступы диалога: 40 снаружи и 24 внутри с каждой стороны. Вычитаются из ширины окна,
  /// чтобы содержимое не выходило за край на узком экране.
  static const _dialogChrome = 128.0;

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
    await widget.onSave(
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
    final width = MediaQuery.sizeOf(context).width - _dialogChrome;
    return AlertDialog(
      title: Text(
        _local
            ? l10n.hostLocalSettingsTitle
            : (widget.existing == null ? l10n.hostsAdd : l10n.navHosts),
      ),
      // Прокрутка на всю ширину диалога, чтобы полоса прокрутки стояла у края окна, а не у края формы.
      // Боковые отступы — внутри прокрутки, поэтому полоса не заходит на поля.
      contentPadding: const EdgeInsets.only(top: AppSpacing.lg),
      content: SingleChildScrollView(
        padding: const EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          bottom: AppSpacing.xl,
        ),
        child: SizedBox(
          key: const ValueKey('host-form-content'),
          width: width.clamp(0, AppLayout.formMaxWidth).toDouble(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_local) ...[
                AppSection(
                  title: l10n.hostFormSectionConnection,
                  children: [
                    SettingsFormRow(
                      title: l10n.hostNameLabel,
                      child: AppTextField(
                        controller: _name,
                        hint: l10n.hostNameHint,
                      ),
                    ),
                    SettingsFormRow(
                      title: l10n.hostAddressLabel,
                      child: AppTextField(
                        controller: _address,
                        hint: l10n.hostAddressHint,
                        error: _addressError,
                      ),
                    ),
                    SettingsFormRow(
                      title: l10n.hostPortLabel,
                      child: AppTextField(
                        controller: _port,
                        hint: '22',
                        error: _portError,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    SettingsFormRow(
                      title: l10n.hostUserLabel,
                      child: AppTextField(
                        controller: _user,
                        hint: l10n.hostUserHint,
                      ),
                    ),
                  ],
                ),
                AppSection(
                  title: l10n.hostOsLabel,
                  description: l10n.hostOsDescription,
                  children: [
                    AppChoiceGroup<HostOs>(
                      iconSize: 40,
                      iconAboveTitle: true,
                      options: [
                        AppChoiceOption(
                          value: HostOs.posix,
                          title: l10n.hostOsPosix,
                          subtitle: l10n.hostOsPosixHint,
                          icon: const AppSvgIcon(_linuxIconAsset),
                        ),
                        AppChoiceOption(
                          value: HostOs.macos,
                          title: l10n.hostOsMacos,
                          subtitle: l10n.hostOsMacosHint,
                          icon: const AppSvgIcon(_macosIconAsset),
                        ),
                        AppChoiceOption(
                          value: HostOs.windows,
                          title: l10n.hostOsWindows,
                          subtitle: l10n.hostOsWindowsHint,
                          icon: const AppSvgIcon(_windowsIconAsset),
                        ),
                      ],
                      selected: _os,
                      onChanged: (value) => setState(() => _os = value),
                    ),
                  ],
                ),
                AppSection(
                  title: l10n.hostFormSectionAuth,
                  children: [
                    AppChoiceGroup<SshAuthType>(
                      options: [
                        AppChoiceOption(
                          value: SshAuthType.key,
                          title: l10n.hostAuthKey,
                          subtitle: l10n.hostAuthKeyDescription,
                          icon: const Icon(Icons.key_outlined),
                        ),
                        AppChoiceOption(
                          value: SshAuthType.password,
                          title: l10n.hostAuthPassword,
                          subtitle: l10n.hostAuthPasswordDescription,
                          icon: const Icon(Icons.password),
                        ),
                      ],
                      selected: _auth,
                      onChanged: (value) => setState(() => _auth = value),
                    ),
                    if (_auth == SshAuthType.key) ...[
                      // Путь к файлу есть только там, где система его отдаёт; на остальных PEM
                      // копируется в поле и уходит в secure storage.
                      if (AppPlatform.current.canOpenExternalKeys)
                        SettingsFormRow(
                          title: l10n.hostKeyPathLabel,
                          child: AppTextField(
                            controller: _keyPath,
                            readOnly: true,
                            hint: l10n.hostKeyFileHint,
                            mono: true,
                          ),
                        ),
                      SettingsFormRow(
                        title: l10n.hostPrivateKeyLabel,
                        description: l10n.hostPrivateKeyHint,
                        child: AppTextField(
                          controller: _privateKey,
                          hint: '-----BEGIN PRIVATE KEY-----',
                          mono: true,
                          minLines: 3,
                          maxLines: 8,
                          suffix: IconButton(
                            tooltip: l10n.hostPickKeyFile,
                            icon: const Icon(Icons.file_open_outlined),
                            onPressed: _pickKeyFile,
                          ),
                        ),
                      ),
                    ],
                    SettingsFormRow(
                      title: l10n.hostSecretLabel,
                      child: AppTextField(
                        controller: _secret,
                        obscure: true,
                        hint: l10n.hostSecretHint,
                      ),
                    ),
                  ],
                ),
              ],
              AppSection(
                title: l10n.hostFormSectionEnvironment,
                children: [
                  SettingsFormRow(
                    title: l10n.hostDefaultWorkspaceLabel,
                    description: l10n.hostWorkspaceDescription,
                    child: AppTextField(
                      controller: _workspace,
                      mono: true,
                      hint: '~/projects',
                      suffix:
                          _local && AppPlatform.current.supportsDirectoryPicker
                          ? IconButton(
                              tooltip: l10n.hostPickFolder,
                              icon: const Icon(Icons.folder_open),
                              onPressed: _pickFolder,
                            )
                          : null,
                    ),
                  ),
                  SettingsFormRow(
                    title: l10n.hostShellLabel,
                    description: l10n.hostShellHint,
                    child: AppTextField(
                      controller: _shell,
                      mono: true,
                      hint: 'bash',
                      error: _shellError,
                    ),
                  ),
                  if (!_local)
                    SettingsFormRow(
                      title: l10n.hostTimeoutLabel,
                      child: AppTextField(
                        controller: _timeout,
                        hint: l10n.hostTimeoutHint,
                        error: _timeoutError,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  SettingsFormRow(
                    title: l10n.hostNotesLabel,
                    child: AppTextField(
                      controller: _notes,
                      hint: l10n.hostNotesHint,
                      minLines: 2,
                      maxLines: 4,
                    ),
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
