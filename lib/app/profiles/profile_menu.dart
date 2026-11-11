import 'package:app_ui/app_ui.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/app/profiles/agent_profile_presentation.dart';
import 'package:probably_works/app/profiles/profile_scope.dart';
import 'package:probably_works/app/profiles/profiles_cubit.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';

/// Переключатель профилей. Смена профиля — это переход на другую ветку
/// маршрута `/a/<profileId>/...`, а не мутация глобального состояния.
class ProfileMenu extends StatelessWidget {
  const ProfileMenu({this.expanded = false, super.key});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final scope = ProfileScope.maybeOf(context);
    if (scope == null) {
      if (!expanded) return const SizedBox.shrink();
      final theme = Theme.of(context);
      return Text(
        AppLocalizations.of(context).appTitle,
        style: theme.textTheme.titleSmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    final cubit = context.read<ProfilesCubit>();
    return BlocBuilder<ProfilesCubit, ProfilesState>(
      bloc: cubit,
      builder: (context, state) {
        final status = state.statuses[scope.profile.id] ?? AgentStatus.online;
        return PopupMenuButton<String>(
          tooltip: AppLocalizations.of(context).agentProfilesTitle,
          onSelected: (id) => _select(context, id),
          itemBuilder: (context) => [
            for (final profile in state.profiles)
              PopupMenuItem(
                value: profile.id,
                child: Row(
                  children: [
                    _StatusDot(status: state.statuses[profile.id]),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(child: Text(_name(context, profile))),
                    if (profile.id == scope.profile.id)
                      const Icon(Icons.check, size: 18),
                  ],
                ),
              ),
          ],
          child: _label(context, scope.profile, status),
        );
      },
    );
  }

  void _select(BuildContext context, String id) {
    final scope = ProfileScope.maybeOf(context);
    if (scope == null || id == scope.profile.id) return;
    context.router.replace(WorkspaceRoute(profileId: id));
  }

  Widget _label(
    BuildContext context,
    AgentProfile profile,
    AgentStatus status,
  ) {
    final theme = Theme.of(context);
    final name = _name(context, profile);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: expanded ? AppSpacing.sm : AppSpacing.xs,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            profile.isLocal ? Icons.computer_outlined : Icons.cloud_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          if (expanded) ...[
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
            _StatusDot(status: status),
            const SizedBox(width: AppSpacing.xs),
            const Icon(Icons.expand_more, size: 18),
          ],
        ],
      ),
    );
  }

  String _name(BuildContext context, AgentProfile profile) =>
      agentProfileTitle(profile, AppLocalizations.of(context));
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
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
