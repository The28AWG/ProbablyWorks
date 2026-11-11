import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/profiles/profile_menu.dart';
import 'package:probably_works/features/chats/presentation/widgets/chat_list_panel.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Развёрнутая боковая панель: кнопка «Новый чат», список чатов по датам и навигация внизу.
/// Используется постоянно в широком режиме и внутри drawer в среднем. Состояние не своё: выбранный чат и
/// активный раздел приходят из маршрутов, а действия выполняет оболочка.
class WorkspaceSidebar extends StatelessWidget {
  const WorkspaceSidebar({
    required this.activeTab,
    required this.selectedChatId,
    required this.onCollapse,
    required this.onOpenChat,
    required this.onNewChat,
    required this.onOpenTab,
    super.key,
  });

  /// Раздел, который открыт сейчас: его пункт навигации выделен.
  final WorkspaceTab activeTab;

  /// Открытый чат: его строка выделена в списке.
  final String? selectedChatId;

  /// Свернуть панель до иконок (широкий режим) или закрыть drawer (средний режим).
  final VoidCallback onCollapse;

  /// Открыть чат из списка.
  final void Function(String chatId) onOpenChat;

  /// Показать стартовый экран нового чата.
  final VoidCallback onNewChat;

  /// Перейти к разделу «Хосты» или «Настройки».
  final void Function(WorkspaceTab tab) onOpenTab;

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
                const Expanded(child: ProfileMenu(expanded: true)),
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
              selectedId: selectedChatId,
              onDeleted: _handleDeleted,
              background: scheme.surfaceContainerLow,
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SidebarRow(
                  icon: Icons.workspaces_outline,
                  label: l10n.navProjects,
                  selected: activeTab == WorkspaceTab.projects,
                  onTap: () => onOpenTab(WorkspaceTab.projects),
                ),
                _SidebarRow(
                  icon: Icons.dns_outlined,
                  label: l10n.navHosts,
                  selected: activeTab == WorkspaceTab.hosts,
                  onTap: () => onOpenTab(WorkspaceTab.hosts),
                ),
                _SidebarRow(
                  icon: Icons.settings_outlined,
                  label: l10n.navSettings,
                  selected: activeTab == WorkspaceTab.settings,
                  onTap: () => onOpenTab(WorkspaceTab.settings),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Удалён открытый чат: показываем стартовый экран, а не пустоту.
  void _handleDeleted(String chatId) {
    if (chatId == selectedChatId) onNewChat();
  }
}

/// Свёрнутая боковая панель: только иконки. Развернуть, создать чат, перейти к хостам и настройкам.
/// Активный раздел отмечен выделенной иконкой.
class WorkspaceRail extends StatelessWidget {
  const WorkspaceRail({
    required this.activeTab,
    required this.onExpand,
    required this.onNewChat,
    required this.onOpenTab,
    super.key,
  });

  /// Раздел, который открыт сейчас.
  final WorkspaceTab activeTab;

  /// Развернуть панель (широкий режим) или открыть её как drawer (средний режим).
  final VoidCallback onExpand;

  /// Показать стартовый экран нового чата.
  final VoidCallback onNewChat;

  /// Перейти к разделу «Хосты» или «Настройки».
  final void Function(WorkspaceTab tab) onOpenTab;

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
            const ProfileMenu(),
            IconButton(
              tooltip: l10n.sidebarExpand,
              icon: const Icon(Icons.menu),
              onPressed: onExpand,
            ),
            IconButton(
              tooltip: l10n.chatsNew,
              icon: const Icon(Icons.add),
              onPressed: onNewChat,
            ),
            const Spacer(),
            IconButton(
              tooltip: l10n.navProjects,
              icon: const Icon(Icons.workspaces_outline),
              isSelected: activeTab == WorkspaceTab.projects,
              onPressed: () => onOpenTab(WorkspaceTab.projects),
            ),
            IconButton(
              tooltip: l10n.navHosts,
              icon: const Icon(Icons.dns_outlined),
              isSelected: activeTab == WorkspaceTab.hosts,
              onPressed: () => onOpenTab(WorkspaceTab.hosts),
            ),
            IconButton(
              tooltip: l10n.navSettings,
              icon: const Icon(Icons.settings_outlined),
              isSelected: activeTab == WorkspaceTab.settings,
              onPressed: () => onOpenTab(WorkspaceTab.settings),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// Строка навигации и действий боковой панели: иконка и подпись, фон при наведении.
/// У открытого раздела фон выделен, как и у выбранного чата.
class _SidebarRow extends StatelessWidget {
  const _SidebarRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Основное действие панели: иконка и подпись в акцентном цвете.
  final bool accent;

  /// Раздел открыт: фон и подпись выделены.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
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
                    ? scheme.primary
                    : selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: accent
                        ? scheme.primary
                        : selected
                        ? scheme.onSecondaryContainer
                        : null,
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
