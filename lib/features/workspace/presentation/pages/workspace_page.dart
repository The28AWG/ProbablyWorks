import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/data/chat_draft_store.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/chats/presentation/widgets/chat_list_panel.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:probably_works/features/workspace/presentation/widgets/sidebar_resize_handle.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_sidebar.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Рабочая область в трёх режимах одной оболочки:
/// широкий (от 1100) — боковая панель с чатами и навигацией, её можно свернуть до иконок и растянуть;
/// средний (800–1099) — свёрнутая полоса с иконками, панель открывается как drawer;
/// компактный (до 800) — список на весь экран с нижней навигацией, чат открывается отдельным маршрутом.
@RoutePage()
class WorkspacePage extends StatelessWidget {
  const WorkspacePage({super.key});

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
    providers: [
      BlocProvider(
        create: (_) =>
            ChatListCubit(getIt<AgentHub>(), getIt<ChatDraftStore>()),
      ),
      BlocProvider(
        create: (_) => SidebarCubit(
          getIt<SettingsRepository>(),
          getIt<SidebarStartupWidth>().value,
        ),
      ),
    ],
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width >= AppBreakpoints.wide) return const _WideWorkspace();
        if (width >= AppBreakpoints.medium) return const _MediumWorkspace();
        return const _CompactWorkspace();
      },
    ),
  );
}

typedef _DestinationSpec = ({
  IconData icon,
  IconData selectedIcon,
  String label,
});

List<_DestinationSpec> _destinationSpecs(AppLocalizations l10n) => [
  (icon: Icons.forum_outlined, selectedIcon: Icons.forum, label: l10n.navChats),
  (icon: Icons.dns_outlined, selectedIcon: Icons.dns, label: l10n.navHosts),
  (
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    label: l10n.navSettings,
  ),
];

/// Широкий режим: панель слева, её можно свернуть до полосы с иконками и растянуть ручкой справа.
/// Ширина анимируется при сворачивании; во время перетаскивания ручкой она следует за курсором.
class _WideWorkspace extends StatefulWidget {
  const _WideWorkspace();

  @override
  State<_WideWorkspace> createState() => _WideWorkspaceState();
}

class _WideWorkspaceState extends State<_WideWorkspace> {
  var _collapsed = false;
  var _resizing = false;

  void _toggle() => setState(() => _collapsed = !_collapsed);

  void _beginResize() => setState(() => _resizing = true);

  void _endResize() => setState(() => _resizing = false);

  @override
  Widget build(BuildContext context) {
    final sidebarWidth = context.select<SidebarCubit, double>(
      (cubit) => cubit.state.width,
    );
    return Scaffold(
      body: Row(
        children: [
          AnimatedContainer(
            // Перетаскивание не анимируем: иначе панель отстаёт от курсора.
            duration: _resizing ? Duration.zero : AppDurations.normal,
            curve: Curves.easeOutCubic,
            width: _collapsed ? AppLayout.railWidth : sidebarWidth,
            child: ClipRect(
              child: OverflowBox(
                alignment: AlignmentDirectional.centerStart,
                maxWidth: double.infinity,
                child: AnimatedSwitcher(
                  duration: AppDurations.fast,
                  child: _collapsed
                      ? WorkspaceRail(
                          key: const ValueKey('rail'),
                          onExpand: _toggle,
                        )
                      : SizedBox(
                          key: const ValueKey('sidebar'),
                          width: sidebarWidth,
                          child: WorkspaceSidebar(
                            onCollapse: _toggle,
                            onOpenChat: (id) =>
                                context.read<ChatListCubit>().select(id),
                          ),
                        ),
                ),
              ),
            ),
          ),
          SidebarResizeHandle(
            enabled: !_collapsed,
            onDragStart: _beginResize,
            onDragEnd: _endResize,
          ),
          const Expanded(child: _ChatArea()),
        ],
      ),
    );
  }
}

/// Средний режим: свёрнутая полоса слева, панель с чатами и навигацией открывается как drawer.
class _MediumWorkspace extends StatelessWidget {
  const _MediumWorkspace();

  /// Выбор чата закрывает drawer: дальше пользователь видит чат, а не список.
  void _openChatFromDrawer(BuildContext drawerContext, String id) {
    drawerContext.read<ChatListCubit>().select(id);
    Scaffold.of(drawerContext).closeDrawer();
  }

  @override
  Widget build(BuildContext context) {
    final sidebarWidth = context.select<SidebarCubit, double>(
      (cubit) => cubit.state.width,
    );
    return Scaffold(
      drawer: Builder(
        builder: (drawerContext) => Drawer(
          width: sidebarWidth,
          child: SafeArea(
            child: WorkspaceSidebar(
              onCollapse: () => Scaffold.of(drawerContext).closeDrawer(),
              onOpenChat: (id) => _openChatFromDrawer(drawerContext, id),
            ),
          ),
        ),
      ),
      body: Row(
        children: [
          Builder(
            builder: (railContext) => WorkspaceRail(
              onExpand: () => Scaffold.of(railContext).openDrawer(),
            ),
          ),
          const VerticalDivider(width: 1),
          const Expanded(child: _ChatArea()),
        ],
      ),
    );
  }
}

class _CompactWorkspace extends StatelessWidget {
  const _CompactWorkspace();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final specs = _destinationSpecs(l10n);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navChats),
        actions: [
          IconButton(
            tooltip: l10n.chatsNew,
            icon: const Icon(Icons.add),
            onPressed: () => createChat(
              context,
              onOpen: (id) => context.router.push(ChatRoute(chatId: id)),
            ),
          ),
        ],
      ),
      body: ChatListPanel(
        onOpen: (id) => context.router.push(ChatRoute(chatId: id)),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (index) =>
            _onDestination(context, WorkspaceDestination.values[index]),
        destinations: [
          for (final spec in specs)
            NavigationDestination(
              icon: Icon(spec.icon),
              selectedIcon: Icon(spec.selectedIcon),
              label: spec.label,
            ),
        ],
      ),
    );
  }

  void _onDestination(BuildContext context, WorkspaceDestination destination) {
    if (destination == WorkspaceDestination.chats) return;
    openWorkspaceDestination(context, destination);
  }
}

class _ChatArea extends StatelessWidget {
  const _ChatArea();

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<ChatListCubit, ChatListState>(
        buildWhen: (a, b) => a.selectedId != b.selectedId,
        builder: (context, state) {
          final id = state.selectedId;
          if (id == null) {
            return AppEmptyState(
              icon: Icons.chat_bubble_outline,
              title: AppLocalizations.of(context).chatsSelectHint,
            );
          }
          // Чат уже есть в списке: передаём его в блок, чтобы шапка и композер открылись сразу.
          return ChatView(
            chatId: id,
            seedChat: state.chats.where((c) => c.id == id).firstOrNull,
            seedHosts: state.hosts,
          );
        },
      );
}
