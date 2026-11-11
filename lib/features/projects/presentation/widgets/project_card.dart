import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/project.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Карточка проекта в списке: имя, хост, папка и число чатов.
/// Архивный проект помечается статусом: чатов нет, через неделю он удалится.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    required this.project,
    required this.host,
    required this.chatCount,
    required this.onTap,
    super.key,
  });

  final Project project;
  final Host? host;
  final int chatCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final hostName = host == null
        ? project.hostId
        : hostDisplayName(host!, l10n);
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: AppRadius.mdAll,
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Icon(
                Icons.workspaces_outline,
                size: 24,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        project.name,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (project.isArchived)
                      StatusChip(
                        label: l10n.projectsArchivedBadge,
                        tone: AppTone.neutral,
                        icon: Icons.archive_outlined,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '$hostName · ${project.workspace}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: muted,
                    fontFamily: AppTheme.monoFamily,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.projectsChatCount(chatCount),
                  style: theme.textTheme.labelSmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
