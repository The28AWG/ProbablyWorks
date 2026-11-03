import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/chats/presentation/widgets/chat_list_panel.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Пункты навигации. Чаты открываются внутри оболочки, хосты и настройки — отдельными маршрутами.
enum WorkspaceDestination { chats, hosts, settings }

void openWorkspaceDestination(
  BuildContext context,
  WorkspaceDestination destination,
) {
  switch (destination) {
    case WorkspaceDestination.chats:
      return;
    case WorkspaceDestination.hosts:
      context.router.push(const HostsRoute());
    case WorkspaceDestination.settings:
      context.router.push(const SettingsRoute());
  }
}

/// «Новый чат»: снимает выбор и показывает стартовый экран. Чат создастся при первой отправке.
void openNewChat(BuildContext context) =>
    context.read<ChatListCubit>().select(null);

/// Развёрнутая боковая панель: кнопка «Новый чат», список чатов по датам и навигация внизу.
/// Используется постоянно в широком режиме и внутри drawer в среднем.
class WorkspaceSidebar extends StatelessWidget {
  const WorkspaceSidebar({
    required this.onCollapse,
    required this.onOpenChat,
    required this.onNewChat,
    super.key,
  });

  /// Свернуть панель до иконок (широкий режим) или закрыть drawer (средний режим).
  final VoidCallback onCollapse;

  /// Открыть чат из списка.
  final void Function(String chatId) onOpenChat;

  /// Показать стартовый экран нового чата.
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.sm + AppSpacing.md,
              top: AppSpacing.sm,
              right: AppSpacing.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.max,
              spacing: AppSpacing.sm,
              children: [
                Expanded(
                  child: Text(
                    l10n.appTitle * 1,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: l10n.sidebarCollapse,
                  icon: const Icon(Icons.menu_open),
                  onPressed: onCollapse,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: _SidebarRow(
              icon: Icons.add,
              label: l10n.chatsNew,
              accent: true,
              onTap: onNewChat,
            ),
          ),
          Expanded(
            child: ChatListPanel(
              onOpen: onOpenChat,
              background: scheme.surfaceContainerLow,
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.sm,
              right: AppSpacing.sm,
              bottom: AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SidebarRow(
                  icon: Icons.dns_outlined,
                  label: l10n.navHosts,
                  onTap: () => openWorkspaceDestination(
                    context,
                    WorkspaceDestination.hosts,
                  ),
                ),
                _SidebarRow(
                  icon: Icons.settings_outlined,
                  label: l10n.navSettings,
                  onTap: () => openWorkspaceDestination(
                    context,
                    WorkspaceDestination.settings,
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

/// Свёрнутая боковая панель: только иконки. Развернуть или открыть список, создать чат, перейти к хостам и настройкам.
class WorkspaceRail extends StatelessWidget {
  const WorkspaceRail({required this.onExpand, super.key});

  /// Развернуть панель (широкий режим) или открыть её как drawer (средний режим).
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SizedBox(
        width: AppLayout.railWidth,
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.sm),
            IconButton(
              tooltip: l10n.sidebarExpand,
              icon: const Icon(Icons.menu),
              onPressed: onExpand,
            ),
            IconButton(
              tooltip: l10n.chatsNew,
              icon: const Icon(Icons.add),
              onPressed: () => openNewChat(context),
            ),
            const Spacer(),
            IconButton(
              tooltip: l10n.navHosts,
              icon: const Icon(Icons.dns_outlined),
              onPressed: () =>
                  openWorkspaceDestination(context, WorkspaceDestination.hosts),
            ),
            IconButton(
              tooltip: l10n.navSettings,
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => openWorkspaceDestination(
                context,
                WorkspaceDestination.settings,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// Строка навигации и действий боковой панели: иконка и подпись, фон при наведении.
class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Основное действие панели: иконка и подпись в акцентном цвете.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: AppRadius.mdAll,
      child: InkWell(
        borderRadius: AppRadius.mdAll,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: accent
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: accent ? theme.colorScheme.primary : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
