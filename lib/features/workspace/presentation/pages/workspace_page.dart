import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/chats/presentation/widgets/chat_list_panel.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Рабочая область в трёх режимах одной оболочки:
/// широкий (от 1100) — навигация, список и чат рядом;
/// средний (800–1099) — навигация и чат, список в drawer;
/// компактный (до 800) — список на весь экран с нижней навигацией, чат открывается отдельным маршрутом.
@RoutePage()
class WorkspacePage extends StatelessWidget {
  const WorkspacePage({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => ChatListCubit(getIt<AgentHub>()),
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

/// Пункты навигации. Чаты открываются внутри оболочки, хосты и настройки — отдельными маршрутами.
enum _Destination { chats, hosts, settings }

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

void _openDestination(BuildContext context, _Destination destination) {
  switch (destination) {
    case _Destination.chats:
      return;
    case _Destination.hosts:
      context.router.push(const HostsRoute());
    case _Destination.settings:
      context.router.push(const SettingsRoute());
  }
}

class _NavRail extends StatelessWidget {
  const _NavRail({required this.onChats});

  /// Вызывается при выборе «Чаты»: в среднем режиме открывает drawer.
  final void Function(BuildContext context) onChats;

  void _onDestinationSelected(BuildContext railContext, int index) {
    final destination = _Destination.values[index];
    if (destination == _Destination.chats) {
      onChats(railContext);
    } else {
      _openDestination(railContext, destination);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final specs = _destinationSpecs(l10n);
    return Builder(
      builder: (railContext) => NavigationRail(
        selectedIndex: 0,
        labelType: NavigationRailLabelType.all,
        onDestinationSelected: (index) =>
            _onDestinationSelected(railContext, index),
        destinations: [
          for (final spec in specs)
            NavigationRailDestination(
              icon: Icon(spec.icon),
              selectedIcon: Icon(spec.selectedIcon),
              label: Text(spec.label),
            ),
        ],
      ),
    );
  }
}

class _WideWorkspace extends StatelessWidget {
  const _WideWorkspace();

  static void _ignoreChatsRailTap(BuildContext _) {
    return;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Row(
      children: [
        const _NavRail(onChats: _WideWorkspace._ignoreChatsRailTap),
        SizedBox(
          width: AppLayout.chatListWidth,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: ChatListPanel(
              onOpen: (id) => context.read<ChatListCubit>().select(id),
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        const Expanded(child: _ChatArea()),
      ],
    ),
  );
}

class _MediumWorkspace extends StatelessWidget {
  const _MediumWorkspace();

  void _openChatFromDrawer(BuildContext drawerContext, String id) {
    drawerContext.read<ChatListCubit>().select(id);
    Scaffold.of(drawerContext).closeDrawer();
  }

  void _openChatsDrawer(BuildContext railContext) {
    Scaffold.of(railContext).openDrawer();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    drawer: Builder(
      builder: (drawerContext) => Drawer(
        width: 320,
        child: SafeArea(
          child: ChatListPanel(
            onOpen: (id) => _openChatFromDrawer(drawerContext, id),
          ),
        ),
      ),
    ),
    body: Row(
      children: [
        _NavRail(onChats: _openChatsDrawer),
        const VerticalDivider(width: 1),
        const Expanded(child: _ChatArea()),
      ],
    ),
  );
}

class _CompactWorkspace extends StatelessWidget {
  const _CompactWorkspace();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final specs = _destinationSpecs(l10n);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.navChats)),
      body: ChatListPanel(
        onOpen: (id) => context.router.push(ChatRoute(chatId: id)),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (index) =>
            _openDestination(context, _Destination.values[index]),
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
}

class _ChatArea extends StatelessWidget {
  const _ChatArea();

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<ChatListCubit, ChatListState>(
        buildWhen: (a, b) => a.selectedId != b.selectedId,
        builder: (context, state) => state.selectedId == null
            ? AppEmptyState(
                icon: Icons.chat_bubble_outline,
                title: AppLocalizations.of(context).chatsSelectHint,
              )
            : ChatView(chatId: state.selectedId!),
      );
}
