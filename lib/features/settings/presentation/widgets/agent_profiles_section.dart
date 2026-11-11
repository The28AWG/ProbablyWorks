import 'package:app_ui/app_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/app/profiles/agent_profile_presentation.dart';
import 'package:probably_works/app/profiles/profiles_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';

/// Список локального и удалённых агентов, добавление и редактирование.
class AgentProfilesSection extends StatelessWidget {
  const AgentProfilesSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocBuilder<ProfilesCubit, ProfilesState>(
      builder: (context, state) => AppSection(
        title: l10n.settingsGroupAgents,
        description: l10n.settingsGroupAgentsHint,
        trailing: FilledButton.icon(
          onPressed: () => _edit(context),
          icon: const Icon(Icons.add),
          label: Text(l10n.agentProfilesAdd),
        ),
        children: [
          for (final profile in state.profiles)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _ProfileCard(
                profile: profile,
                status: state.statuses[profile.id],
                onEdit: profile.isLocal ? null : () => _edit(context, profile),
                onRemove: profile.isLocal
                    ? null
                    : () => context.read<ProfilesCubit>().removeRemote(
                        profile.id,
                      ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, [AgentProfile? profile]) async {
    final l10n = AppLocalizations.of(context);
    final name = TextEditingController(text: profile?.name ?? '');
    final url = TextEditingController(text: profile?.baseUri?.toString() ?? '');
    final token = TextEditingController();
    final cubit = context.read<ProfilesCubit>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          profile == null ? l10n.agentProfilesAdd : l10n.agentProfilesEdit,
        ),
        content: SizedBox(
          width: AppLayout.dialogWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: InputDecoration(labelText: l10n.agentProfilesName),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: url,
                decoration: InputDecoration(labelText: l10n.agentProfilesUrl),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: token,
                obscureText: true,
                decoration: InputDecoration(labelText: l10n.agentProfilesToken),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.agentProfilesCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.agentProfilesSave),
          ),
        ],
      ),
    );
    if (saved != true || !context.mounted) return;
    final uri = Uri.tryParse(url.text.trim());
    if (name.text.trim().isEmpty ||
        uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        (profile == null && token.text.trim().isEmpty)) {
      AppSnackBar.show(context, l10n.agentProfilesInvalid);
      return;
    }
    try {
      if (profile == null) {
        await cubit.addRemote(
          name: name.text,
          baseUri: uri,
          token: token.text.trim(),
        );
      } else {
        await cubit.updateRemote(
          profile.id,
          name: name.text,
          baseUri: uri,
          token: token.text.trim().isEmpty ? null : token.text.trim(),
        );
      }
    } on Object catch (error) {
      if (context.mounted) AppSnackBar.show(context, '$error');
    }
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.status,
    required this.onEdit,
    required this.onRemove,
  });

  final AgentProfile profile;
  final AgentStatus? status;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      child: Row(
        children: [
          Icon(agentProfileIcon(profile), color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  agentProfileTitle(profile, l10n),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  profile.isLocal
                      ? l10n.agentProfilesLocalHint
                      : profile.baseUri?.toString() ?? '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          _StatusDot(status: status),
          if (onEdit != null)
            IconButton(
              tooltip: l10n.agentProfilesEdit,
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
          if (onRemove != null)
            IconButton(
              tooltip: l10n.agentProfilesRemove,
              onPressed: onRemove,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final AgentStatus? status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      AgentStatus.online => scheme.primary,
      AgentStatus.connecting => scheme.tertiary,
      AgentStatus.offline => scheme.error,
      null => scheme.outline,
    };
    return Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
