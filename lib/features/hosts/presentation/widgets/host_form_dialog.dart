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

/// Открывает редактор хоста. [existing] null — новый хост (тип выбирается в форме); для локального хоста
/// редактируется только окружение. Сохранение идёт через [HostsCubit], который должен быть в контексте.
Future<void> showHostFormDialog(BuildContext context, {Host? existing}) {
  final cubit = context.read<HostsCubit>();
  return showDialog<void>(
    context: context,
    builder: (_) => HostFormDialog(existing: existing, onSave: cubit.save),
  );
}

/// Диалог «Хост»: тип, подключение, аутентификация и окружение. Строки формы — как в настройках:
/// название и пояснение слева, поле справа; подписей над полями нет. Ширина до
/// `AppLayout.formMaxWidth`, на узком экране строки складываются сами.
///
/// У виртуального хоста нет адреса, ОС, аутентификации, shell и таймаута: всё это относится к сети и
/// реальной оболочке, а песочница живёт внутри приложения. Поля, которых нет в режиме, не валидируются и
/// не попадают в сохраняемую запись.
class HostFormDialog extends StatefulWidget {
  const HostFormDialog({required this.onSave, this.existing, super.key});

  /// Редактируемый хост. Null — новый хост; его тип (SSH или виртуальный) выбирается в форме.
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

  /// Локальный хост редактируется только в части окружения; его тип фиксирован.
  late final _local = widget.existing?.isLocal ?? false;
  late HostKind _kind = widget.existing?.kind ?? HostKind.ssh;
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

  /// Режим SSH: показываются поля подключения, ОС и аутентификации.
  bool get _ssh => _kind == HostKind.ssh;

  /// Режим виртуального хоста: название, рабочая папка, заметки и переменные.
  bool get _virtual => _kind == HostKind.virtual;

  /// Пары «имя / значение». Пустые строки при сохранении отбрасываются.
  late final List<_EnvRow> _env = [
    for (final entry
        in widget.existing?.environment.entries ??
            const <MapEntry<String, String>>[])
      _EnvRow(entry.key, entry.value),
  ];

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
    for (final row in _env) {
      row.dispose();
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

  /// Проверяет поля текущего режима; возвращает true, если можно сохранять. Поля скрытого режима не проверяем:
  /// их значения в запись не попадают, и ошибка по ним пользователю была бы непонятна.
  bool _validate(AppLocalizations l10n) {
    final port = int.tryParse(_port.text.trim());
    final timeoutText = _timeout.text.trim();
    final timeout = int.tryParse(timeoutText);
    final shell = _shell.text.trim();
    var environmentOk = true;
    setState(() {
      _addressError = _ssh && _address.text.trim().isEmpty
          ? l10n.hostAddressRequired
          : null;
      _portError = _ssh && (port == null || port < 1 || port > 65535)
          ? l10n.hostPortInvalid
          : null;
      _timeoutError =
          _ssh && timeoutText.isNotEmpty && (timeout == null || timeout <= 0)
          ? l10n.hostTimeoutInvalid
          : null;
      _shellError =
          !_virtual && shell.isNotEmpty && !ProcessControl.isValidShell(shell)
          ? l10n.hostShellInvalid
          : null;
      environmentOk = _validateEnvironment(l10n);
    });
    return _addressError == null &&
        _portError == null &&
        _timeoutError == null &&
        _shellError == null &&
        environmentOk;
  }

  /// Пустая строка не ошибка: она не сохраняется. Имя проверяется тем же правилом, что и репозиторий.
  /// Повтор имени — та же ошибка у второй строки, иначе в карте осталось бы незаметное затирание.
  bool _validateEnvironment(AppLocalizations l10n) {
    var ok = true;
    final seen = <String>{};
    for (final row in _env) {
      final name = row.name.text.trim();
      if (name.isEmpty && row.value.text.isEmpty) {
        row.nameError = null;
        continue;
      }
      if (!isHostEnvironmentName(name) || !seen.add(name)) {
        row.nameError = l10n.hostEnvironmentNameInvalid;
        ok = false;
        continue;
      }
      row.nameError = null;
    }
    return ok;
  }

  Map<String, String> _collectedEnvironment() {
    final environment = <String, String>{};
    for (final row in _env) {
      final name = row.name.text.trim();
      if (name.isEmpty && row.value.text.isEmpty) continue;
      environment[name] = row.value.text;
    }
    return environment;
  }

  void _addEnvironment() => setState(() => _env.add(_EnvRow('', '')));

  void _removeEnvironment(int index) =>
      setState(() => _env.removeAt(index).dispose());

  Future<void> _saveHost(AppLocalizations l10n) async {
    if (!_validate(l10n)) return;
    final host = _build(l10n);
    await widget.onSave(
      host,
      secret: _ssh ? _secret.text : null,
      privateKeyPem: !_ssh || _auth != SshAuthType.key
          ? null
          : _privateKey.text,
    );
    if (!mounted) return;
    Navigator.pop(context);
  }

  Host _build(AppLocalizations l10n) {
    final existing = widget.existing;
    final now = DateTime.now();
    String? orNull(String value) => value.trim().isEmpty ? null : value.trim();
    final name = _name.text.trim().isEmpty
        ? (_virtual ? l10n.hostVirtualDefaultName : _address.text.trim())
        : _name.text.trim();
    return Host(
      id: existing?.id ?? const Uuid().v4(),
      name: _local ? existing!.name : name,
      kind: _kind,
      address: _ssh ? _address.text.trim() : null,
      port: _ssh ? int.parse(_port.text.trim()) : (existing?.port ?? 22),
      username: _ssh ? orNull(_user.text) : null,
      authType: _auth,
      keyPath:
          !_ssh ||
              _auth != SshAuthType.key ||
              !AppPlatform.current.canOpenExternalKeys
          ? null
          : orNull(_keyPath.text),
      hostKeyFingerprint: existing?.hostKeyFingerprint,
      os: _ssh ? _os : (existing?.os ?? HostOs.posix),
      defaultWorkspace: orNull(_workspace.text),
      shellOverride: _virtual ? null : orNull(_shell.text),
      notes: orNull(_notes.text),
      connectTimeoutSeconds: _ssh ? int.tryParse(_timeout.text.trim()) : null,
      lastCheckAt: existing?.lastCheckAt,
      lastLatencyMs: existing?.lastLatencyMs,
      lastCheckError: existing?.lastCheckError,
      environment: _collectedEnvironment(),
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
              // Тип выбирается только при создании: переключать SSH и виртуальный у существующего хоста
              // нельзя, потому что у них разные данные (адрес против файлов песочницы).
              if (widget.existing == null)
                AppSection(
                  title: l10n.hostKindLabel,
                  description: l10n.hostKindDescription,
                  children: [
                    AppChoiceGroup<HostKind>(
                      options: [
                        AppChoiceOption(
                          value: HostKind.ssh,
                          title: l10n.hostKindSsh,
                          subtitle: l10n.hostKindSshHint,
                          icon: const Icon(Icons.dns_outlined),
                        ),
                        AppChoiceOption(
                          value: HostKind.virtual,
                          title: l10n.hostKindVirtual,
                          subtitle: l10n.hostKindVirtualHint,
                          icon: const Icon(Icons.memory_outlined),
                        ),
                      ],
                      selected: _kind,
                      onChanged: (value) => setState(() => _kind = value),
                    ),
                  ],
                ),
              if (!_local) ...[
                AppSection(
                  title: _virtual
                      ? l10n.hostFormSectionVirtual
                      : l10n.hostFormSectionConnection,
                  description: _virtual ? l10n.hostVirtualDescription : null,
                  children: [
                    SettingsFormRow(
                      title: l10n.hostNameLabel,
                      child: AppTextField(
                        controller: _name,
                        hint: _virtual
                            ? l10n.hostVirtualDefaultName
                            : l10n.hostNameHint,
                      ),
                    ),
                    if (_ssh) ...[
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
                  ],
                ),
                if (_ssh) ...[
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
                  // Оболочка виртуального хоста фиксирована (`/bin/sh` с набором апплетов), подменять её нечем.
                  if (!_virtual)
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
                  if (_ssh)
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
                  _EnvironmentEditor(
                    rows: _env,
                    onAdd: _addEnvironment,
                    onRemove: _removeEnvironment,
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

/// Список пар «имя / значение» на всю ширину формы. Пустые строки отбрасывает сохранение.
class _EnvironmentEditor extends StatelessWidget {
  const _EnvironmentEditor({
    required this.rows,
    required this.onAdd,
    required this.onRemove,
  });

  final List<_EnvRow> rows;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.hostEnvironmentLabel, style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        Text(
          l10n.hostEnvironmentHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        for (var i = 0; i < rows.length; i++) ...[
          // Строка на всю ширину формы, а не в правой колонке подписи: там имя и значение
          // делили узкую половину, и ошибка имени обрезалась.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: AppTextField(
                  controller: rows[i].name,
                  hint: l10n.hostEnvironmentNameHint,
                  error: rows[i].nameError,
                  errorMaxLines: 8,
                  mono: true,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppTextField(
                  controller: rows[i].value,
                  hint: l10n.hostEnvironmentValueHint,
                  mono: true,
                ),
              ),
              IconButton(
                tooltip: l10n.hostEnvironmentRemove,
                icon: const Icon(Icons.close),
                onPressed: () => onRemove(i),
              ),
            ],
          ),
          if (i != rows.length - 1) const SizedBox(height: AppSpacing.sm),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: Text(l10n.hostEnvironmentAdd),
          ),
        ),
      ],
    );
  }
}

/// Одна пара переменной в форме. Контроллеры живут, пока строка в списке.
class _EnvRow {
  _EnvRow(String name, String value)
    : name = TextEditingController(text: name),
      value = TextEditingController(text: value);

  final TextEditingController name;
  final TextEditingController value;
  String? nameError;

  void dispose() {
    name.dispose();
    value.dispose();
  }
}
