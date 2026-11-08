import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/project.dart';
import 'package:probably_works/agent/policy/security_profile.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/data/policy_profile_repository.dart';
import 'package:probably_works/core/data/project_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/features/settings/presentation/widgets/security_profile_editor.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:uuid/uuid.dart';

/// Открывает редактор именованного профиля политики для проекта.
///
/// Новый профиль создаётся из глобальной политики, чтобы пользователь менял только отличия.
/// При сохранении профиль привязывается к проекту; при удалении проект возвращается к глобальной политике.
Future<void> showPolicyProfileDialog(
  BuildContext context, {
  required Project project,
  PolicyProfile? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => _PolicyProfileDialog(project: project, existing: existing),
);

class _PolicyProfileDialog extends StatefulWidget {
  const _PolicyProfileDialog({required this.project, this.existing});

  final Project project;
  final PolicyProfile? existing;

  @override
  State<_PolicyProfileDialog> createState() => _PolicyProfileDialogState();
}

class _PolicyProfileDialogState extends State<_PolicyProfileDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _description = TextEditingController(
    text: widget.existing?.description ?? '',
  );
  late SecurityProfile _profile = const SecurityProfile();
  String _denylist = '';
  bool _saving = false;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = getIt<SettingsRepository>();
    final denylist = await settings.readDenylist();
    final global = await settings.readSecurityProfile();
    if (!mounted) return;
    setState(() {
      _denylist = denylist.join('\n');
      _profile = widget.existing?.profile ?? global;
    });
  }

  void _onNameChanged(String _) {
    if (_nameError != null) setState(() => _nameError = null);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        widget.existing == null
            ? l10n.projectsPolicyCreate
            : l10n.projectsPolicyEdit,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      contentPadding: const EdgeInsets.only(top: AppSpacing.lg),
      content: SingleChildScrollView(
        padding: const EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          bottom: AppSpacing.xl,
        ),
        child: SizedBox(
          width: 720,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(
                controller: _name,
                label: l10n.projectsPolicyName,
                error: _nameError,
                onChanged: _onNameChanged,
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _description,
                label: l10n.projectsPolicyDescription,
                error: null,
              ),
              const SizedBox(height: AppSpacing.lg),
              SecurityProfileEditor(
                profile: _profile,
                denylist: _denylist,
                onChanged: (value) => setState(() => _profile = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            onPressed: _saving ? null : _delete,
            child: Text(
              l10n.projectsPolicyDelete,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = l10n.commonRequired);
      return;
    }
    setState(() {
      _nameError = null;
      _saving = true;
    });
    try {
      final now = DateTime.now();
      final profile = PolicyProfile(
        id: widget.existing?.id ?? const Uuid().v4(),
        name: name,
        description: _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        profile: _profile,
        createdAt: widget.existing?.createdAt ?? now,
        updatedAt: now,
      );
      await getIt<PolicyProfileRepository>().save(profile);
      if (!mounted) return;
      await getIt<ProjectRepository>().save(
        widget.project.copyWith(policyProfileId: profile.id),
      );
      if (!mounted) return;
      Navigator.pop(context);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppSnackBar.show(context, l10n.commonError('$error'));
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final l10n = AppLocalizations.of(context);
    final ok = await ConfirmDialog.confirm(
      context,
      title: l10n.projectsPolicyDelete,
      message: l10n.projectsPolicyDeleteConfirm(existing.name),
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonDelete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await getIt<PolicyProfileRepository>().delete(existing.id);
      if (!mounted) return;
      await getIt<ProjectRepository>().save(
        widget.project.copyWith(clearPolicyProfile: true),
      );
      if (!mounted) return;
      Navigator.pop(context);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppSnackBar.show(context, l10n.commonError('$error'));
    }
  }
}
