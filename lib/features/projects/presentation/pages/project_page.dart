import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/project.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/local_host_presentation.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/data/policy_profile_repository.dart';
import 'package:probably_works/core/data/project_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/projects/presentation/bloc/projects_cubit.dart';
import 'package:probably_works/features/projects/presentation/widgets/policy_profile_dialog.dart';
import 'package:probably_works/features/settings/presentation/pages/settings_page.dart';
import 'package:probably_works/features/settings/presentation/widgets/settings_form_row.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Карточка проекта: имя, неизменяемые хост и папка, профиль политики, доверие,
/// skills и общая память. Факты меняются только здесь или подтверждённым инструментом агента.
@RoutePage()
class ProjectPage extends StatelessWidget {
  const ProjectPage({
    @PathParam('projectId') required this.projectId,
    super.key,
  });

  final String projectId;

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
      body: BlocBuilder<ProjectsCubit, ProjectsState>(
        builder: (context, state) {
          final project = state.projects
              .where((project) => project.id == projectId)
              .firstOrNull;
          if (project == null) {
            if (state.loading) {
              return const Center(child: CircularProgressIndicator());
            }
            return AppEmptyState(
              icon: Icons.workspaces_outline,
              title: l10n.projectsNotFound,
            );
          }
          return _ProjectBody(
            project: project,
            host: state.hostOf(project),
            chatCount: state.chatCountOf(project),
          );
        },
      ),
    );
  }
}

class _ProjectBody extends StatelessWidget {
  const _ProjectBody({
    required this.project,
    required this.host,
    required this.chatCount,
  });

  final Project project;
  final Host? host;
  final int chatCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final hostName = host == null
        ? project.hostId
        : hostDisplayName(host!, l10n);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: AppRadius.lgAll,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Icon(
                  Icons.workspaces_outline,
                  size: 32,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          project.name,
                          style: theme.textTheme.headlineSmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.projectsRename,
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _rename(context),
                      ),
                    ],
                  ),
                  if (project.isArchived) ...[
                    const SizedBox(height: AppSpacing.xs),
                    StatusChip(
                      label: l10n.projectsArchivedBadge,
                      tone: AppTone.neutral,
                      icon: Icons.archive_outlined,
                    ),
                  ],
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
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xl),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsFormRow(
                title: l10n.projectsHostLabel,
                child: SelectableText(
                  hostName,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const Divider(height: AppSpacing.xl),
              SettingsFormRow(
                title: l10n.projectsWorkspaceLabel,
                child: SelectableText(
                  project.workspace,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: AppTheme.monoFamily,
                  ),
                ),
              ),
              const Divider(height: AppSpacing.xl),
              SettingsFormRow(
                title: l10n.projectsChatsLabel,
                child: Text(
                  l10n.projectsChatCount(chatCount),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        if (project.isArchived) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            l10n.projectsArchivedHint,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _deleteProject(context),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.projectsDeleteNow),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        _PolicySection(project: project),
        const SizedBox(height: AppSpacing.xl),
        _TrustSection(project: project),
        const SizedBox(height: AppSpacing.xl),
        _FactsSection(project: project),
      ],
    );
  }

  Future<void> _rename(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final name = await ConfirmDialog.prompt(
      context,
      title: l10n.projectsRenameTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
      initialText: project.name,
    );
    if (name == null || !context.mounted) return;
    await context.read<ProjectsCubit>().rename(project, name);
  }

  Future<void> _deleteProject(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<ProjectsCubit>();
    final ok = await ConfirmDialog.confirm(
      context,
      title: l10n.projectsDeleteNow,
      message: l10n.projectsDeleteConfirm(project.name),
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonDelete,
      destructive: true,
    );
    if (!ok) return;
    await cubit.deleteProject(project);
    if (context.mounted) await context.router.maybePop();
  }
}

class _PolicySection extends StatelessWidget {
  const _PolicySection({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AppSection(
      title: l10n.projectsPolicyTitle,
      description: l10n.projectsPolicyHint,
      children: [
        AppCard(
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.xs,
            horizontal: AppSpacing.lg,
          ),
          child: StreamBuilder<List<PolicyProfile>>(
            stream: getIt<PolicyProfileRepository>().watchAll(),
            builder: (context, snapshot) {
              final profiles = snapshot.data ?? const <PolicyProfile>[];
              final selected = profiles
                  .where((profile) => profile.id == project.policyProfileId)
                  .firstOrNull;
              final label = selected?.name ?? l10n.projectsPolicyGlobal;
              final actions = _PolicyActions(
                project: project,
                selected: selected,
              );
              return LayoutBuilder(
                builder: (context, constraints) {
                  // Тот же порог, что у строки настроек: подпись и значение
                  // складываются, когда двум колонкам не хватает места.
                  final stacked = constraints.maxWidth < AppLayout.formMaxWidth;
                  // Узкая раскладка: текст на линии заголовка, а подсветка на
                  // [AppSpacing.sm] выходит в поле карточки, чтобы hover не
                  // начинался у глифов. Широкая: подсветка внутри колонки.
                  final field = _PolicyField(
                    project: project,
                    profiles: profiles,
                    label: label,
                    outsetStart: stacked ? AppSpacing.sm : 0,
                    padding: stacked
                        ? const EdgeInsetsDirectional.only(
                            top: AppSpacing.md,
                            end: AppSpacing.md,
                            bottom: AppSpacing.md,
                          )
                        : const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: AppSpacing.md,
                          ),
                  );
                  if (stacked) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.projectsPolicyLabel,
                                style: theme.textTheme.titleSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            actions,
                          ],
                        ),
                        field,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: AppLayout.formLabelWidth,
                        child: Text(
                          l10n.projectsPolicyLabel,
                          style: theme.textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xl),
                      Expanded(child: field),
                      const SizedBox(width: AppSpacing.sm),
                      actions,
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Открывает настройки безопасности: у глобального профиля нет своей карточки.
Future<void> _openPolicySecuritySettings(BuildContext context) async {
  SettingsPage.requestedGroup.value = 'safety';
  showWorkspaceTab(context, WorkspaceTab.settings);
  final tabs = AutoTabsRouter.of(context);
  final stack = tabs.stackRouterOfIndex(WorkspaceTab.settings.index);
  if (stack != null) {
    await stack.replace(SettingsRoute(initialGroup: 'safety'));
  }
}

/// Строка доверия: подпись, пояснение и переключатель.
///
/// Высота равна содержимому, без минимальной высоты [SwitchListTile]. Подсветка
/// на [AppSpacing.sm] шире строки и уходит в поле карточки: текст остаётся на
/// одной линии с соседними подписями, а hover не начинается у глифов.
class _TrustSwitch extends StatelessWidget {
  const _TrustSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          PositionedDirectional(
            start: -AppSpacing.sm,
            end: -AppSpacing.sm,
            top: -AppSpacing.sm,
            bottom: -AppSpacing.sm,
            child: InkWell(
              excludeFromSemantics: true,
              borderRadius: AppRadius.mdAll,
              onTap: () => onChanged(!value),
              child: const SizedBox.expand(),
            ),
          ),
          // Жест у подсветки: иначе переключатель забирает hover и рвёт её.
          // Сам Switch только показывает состояние и остаётся в семантике.
          IgnorePointer(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                ExcludeFocus(
                  child: Switch(
                    value: value,
                    onChanged: onChanged,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrustSection extends StatelessWidget {
  const _TrustSection({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AppSection(
      title: l10n.projectsTrustTitle,
      description: l10n.projectsTrustHint,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TrustSwitch(
                title: l10n.projectsAgentsMd,
                subtitle: l10n.projectsAgentsMdHint,
                value: project.trustAgentsMd,
                onChanged: (value) => context
                    .read<ProjectsCubit>()
                    .setAgentsTrust(project, trusted: value),
              ),
              const Divider(height: AppSpacing.xl),
              Text(l10n.projectsSkillsTitle, style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.lg),
              StreamBuilder<List<ProjectSkill>>(
                stream: getIt<ProjectRepository>().watchSkills(project.id),
                builder: (context, snapshot) {
                  final skills = snapshot.data ?? const <ProjectSkill>[];
                  if (skills.isEmpty) {
                    return Text(
                      l10n.projectsSkillsEmpty,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    );
                  }
                  return Column(
                    // Два выноса подсветки не должны сходиться: между строками остаётся зазор.
                    spacing: AppSpacing.xl,
                    children: [
                      for (final skill in skills)
                        _TrustSwitch(
                          title: skill.name,
                          subtitle: skill.trusted
                              ? l10n.projectsSkillTrusted
                              : l10n.projectsSkillUntrusted,
                          value: skill.trusted,
                          onChanged: (value) =>
                              context.read<ProjectsCubit>().setSkillTrusted(
                                project.id,
                                skill.name,
                                trusted: value,
                              ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FactsSection extends StatelessWidget {
  const _FactsSection({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AppSection(
      title: l10n.projectsFactsTitle,
      description: l10n.projectsFactsHint,
      trailing: TextButton.icon(
        onPressed: () => _addFact(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.projectsAddFact),
      ),
      children: [
        StreamBuilder<List<ProjectFact>>(
          stream: getIt<ProjectRepository>().watchFacts(project.id),
          builder: (context, snapshot) {
            final facts = snapshot.data ?? const <ProjectFact>[];
            if (facts.isEmpty) {
              return Text(
                l10n.projectsFactsEmpty,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              );
            }
            // Тот же зазор, что между детьми секции: карточки не слипаются рамками.
            return Column(
              spacing: AppSpacing.md,
              children: [
                for (final fact in facts)
                  AppCard(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                fact.text,
                                style: theme.textTheme.bodyMedium,
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                _formatDate(fact.createdAt),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: l10n.commonDelete,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteFact(context, fact),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _addFact(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final text = await ConfirmDialog.prompt(
      context,
      title: l10n.projectsAddFact,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
      hint: l10n.projectsFactHint,
      minLines: 2,
      maxLines: 4,
    );
    if (text == null || !context.mounted) return;
    await context.read<ProjectsCubit>().addFact(project, text);
  }

  Future<void> _deleteFact(BuildContext context, ProjectFact fact) async {
    final l10n = AppLocalizations.of(context);
    final ok = await ConfirmDialog.confirm(
      context,
      title: l10n.commonDelete,
      message: l10n.projectsFactDeleteConfirm,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonDelete,
      destructive: true,
    );
    if (ok && context.mounted) {
      await context.read<ProjectsCubit>().deleteFact(fact.id);
    }
  }
}

/// Кнопки профиля: создать, править выбранный или открыть глобальные настройки.
class _PolicyActions extends StatelessWidget {
  const _PolicyActions({required this.project, required this.selected});

  final Project project;
  final PolicyProfile? selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: l10n.projectsPolicyCreate,
          icon: const Icon(Icons.add),
          onPressed: () => showPolicyProfileDialog(context, project: project),
        ),
        if (selected != null)
          IconButton(
            tooltip: l10n.projectsPolicyEdit,
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showPolicyProfileDialog(
              context,
              project: project,
              existing: selected,
            ),
          )
        else
          IconButton(
            tooltip: l10n.settingsGroupSafety,
            icon: const Icon(Icons.tune),
            onPressed: () => _openPolicySecuritySettings(context),
          ),
      ],
    );
  }
}

/// Поле выбора профиля.
///
/// [padding] — внутреннее поле подсветки: между краем hover и текстом.
/// [outsetStart] выносит этот край за границу колонки, когда текст должен
/// остаться на одной линии с заголовком. Ноль — подсветка внутри колонки.
class _PolicyField extends StatelessWidget {
  const _PolicyField({
    required this.project,
    required this.profiles,
    required this.label,
    required this.padding,
    required this.outsetStart,
  });

  final Project project;
  final List<PolicyProfile> profiles;
  final String label;
  final EdgeInsetsGeometry padding;

  /// Насколько подсветка выходит за начало колонки. Текст при этом не сдвигается.
  final double outsetStart;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final menuWidth = _policyMenuWidth(context, constraints.maxWidth);
        // Пункт на всю ширину меню: подпись получает ту же границу,
        // что и рамка, и обрезается многоточием, а не рисуется поверх неё.
        final itemStyle = MenuItemButton.styleFrom(
          minimumSize: Size(menuWidth, kMinInteractiveDimension),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        );
        return MenuAnchor(
          // Иначе панель режется по maximumSize, а дети считаются
          // по своей ширине: рамка сжимается, текст уходит под неё.
          crossAxisUnconstrained: false,
          style: MenuStyle(
            alignment: AlignmentDirectional.bottomStart,
            padding: WidgetStateProperty.all(
              const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            ),
            minimumSize: WidgetStateProperty.all(Size(menuWidth, 0)),
            maximumSize: WidgetStateProperty.all(
              Size(menuWidth, _policyMenuMaxHeight),
            ),
          ),
          menuChildren: [
            _PolicyMenuItem(
              label: l10n.projectsPolicyGlobal,
              style: itemStyle,
              onPressed: () =>
                  context.read<ProjectsCubit>().setPolicyProfile(project, null),
            ),
            for (final profile in profiles)
              _PolicyMenuItem(
                label: profile.name,
                style: itemStyle,
                onPressed: () => context.read<ProjectsCubit>().setPolicyProfile(
                  project,
                  profile.id,
                ),
              ),
          ],
          builder: (context, controller, child) {
            void toggle() =>
                controller.isOpen ? controller.close() : controller.open();
            final row = Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  Icons.arrow_drop_down,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            );
            final ink = InkWell(
              borderRadius: AppRadius.smAll,
              onTap: toggle,
              child: Padding(padding: padding, child: row),
            );
            // Подсветка рисуется отдельным слоем и выходит в поле карточки
            // до текста. Сам текст остаётся на линии заголовка.
            if (outsetStart == 0) return ink;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                ink,
                PositionedDirectional(
                  start: -outsetStart,
                  top: 0,
                  end: 0,
                  bottom: 0,
                  child: InkWell(
                    excludeFromSemantics: true,
                    borderRadius: AppRadius.smAll,
                    onTap: toggle,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Пункт меню профиля: подпись в одну строку и обрезается по ширине пункта.
///
/// Ширина пункта задаётся снаружи и совпадает с рамкой меню. Своя ширина у текста
/// здесь не считается: иначе длинное имя рисуется шире рамки и уходит под неё.
class _PolicyMenuItem extends StatelessWidget {
  const _PolicyMenuItem({
    required this.label,
    required this.style,
    required this.onPressed,
  });

  final String label;
  final ButtonStyle style;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => MenuItemButton(
    style: style,
    onPressed: onPressed,
    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
  );
}

/// Ширина меню профиля политики.
///
/// На узком окне меню занимает доступную ширину экрана: поле уже экрана
/// из-за полей страницы, и длинное имя иначе не помещается в рамку. На широком
/// меню равно ширине поля и не растягивается на всё окно. [anchorWidth] — ширина поля.
double _policyMenuWidth(BuildContext context, double anchorWidth) {
  final screenWidth = MediaQuery.sizeOf(context).width;
  final horizontalPadding = MediaQuery.paddingOf(context).horizontal;
  // MenuAnchor отступает от края оверлея на 8px с каждой стороны — это [AppSpacing.sm].
  final available = screenWidth - horizontalPadding - AppSpacing.sm * 2;
  final capped = available < 0 ? 0.0 : available;
  if (!anchorWidth.isFinite) return capped;
  if (screenWidth < AppBreakpoints.medium) return capped;
  return anchorWidth < capped ? anchorWidth : capped;
}

/// Меню профиля не выше этого: длинный список прокручивается внутри рамки.
const double _policyMenuMaxHeight = 250;

String _formatDate(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
