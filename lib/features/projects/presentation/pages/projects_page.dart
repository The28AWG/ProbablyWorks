import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/projects/presentation/bloc/projects_cubit.dart';
import 'package:probably_works/features/projects/presentation/widgets/project_card.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Вкладка «Проекты»: контейнер вложенного стека со списком и карточкой проекта.
@RoutePage()
class ProjectsTabPage extends AutoRouter {
  const ProjectsTabPage({super.key});
}

/// Список проектов. Проект нельзя создать кнопкой: он появляется вместе с первым чатом
/// в паре «хост + папка», а здесь его можно открыть, переименовать и удалить архивный.
@RoutePage()
class ProjectsPage extends StatelessWidget {
  const ProjectsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppScaffold(
      appBar: AppBar(
        leading: context.workspaceLayout == .compact
            ? const WorkspaceLeadingButton()
            : null,
        title: Text(
          l10n.projectsTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      maxWidth: AppLayout.pageMaxWidth,
      body: BlocBuilder<ProjectsCubit, ProjectsState>(
        builder: (context, state) {
          if (state.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.projects.isEmpty) {
            return AppEmptyState(
              icon: Icons.workspaces_outline,
              title: l10n.projectsEmptyTitle,
              message: l10n.projectsEmptyMessage,
            );
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              if (state.active.isNotEmpty) ...[
                AppSection(
                  title: l10n.projectsActiveSection,
                  children: [
                    for (final project in state.active)
                      ProjectCard(
                        project: project,
                        host: state.hostOf(project),
                        chatCount: state.chatCountOf(project),
                        onTap: () => _open(context, project.id),
                      ),
                  ],
                ),
              ],
              if (state.archived.isNotEmpty) ...[
                if (state.active.isNotEmpty)
                  const SizedBox(height: AppSpacing.xl),
                AppSection(
                  title: l10n.projectsArchivedSection,
                  description: l10n.projectsArchivedHint,
                  children: [
                    for (final project in state.archived)
                      ProjectCard(
                        project: project,
                        host: state.hostOf(project),
                        chatCount: state.chatCountOf(project),
                        onTap: () => _open(context, project.id),
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  void _open(BuildContext context, String projectId) {
    final router = context.router;
    if (router.topRoute.name == ProjectRoute.name &&
        router.topRoute.params.getString('projectId') == projectId) {
      return;
    }
    unawaited(router.push(ProjectRoute(projectId: projectId)));
  }
}
