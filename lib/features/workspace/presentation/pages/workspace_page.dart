import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Адаптивная рабочая область в трёх режимах:
/// широкий (≥1100) — список и чат рядом; средний (800–1099) — рейл и список в drawer;
/// компактный (<800) — список на весь экран, чат открывается отдельным маршрутом.
@RoutePage()
class WorkspacePage extends StatelessWidget {
  const WorkspacePage({super.key});

  static const wideBreakpoint = 1100.0;
  static const mediumBreakpoint = 800.0;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => ChatListCubit(getIt<AgentHub>()),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width >= wideBreakpoint) return const _WideWorkspace();
        if (width >= mediumBreakpoint) return const _MediumWorkspace();
        return const _CompactWorkspace();
      },
    ),
  );
}

class _WideWorkspace extends StatelessWidget {
  const _WideWorkspace();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: const _NavAppBar(),
    body: Row(
      children: [
        SizedBox(
          width: 300,
          child: _ChatListPanel(
            onOpen: (id) => context.read<ChatListCubit>().select(id),
          ),
        ),
        const VerticalDivider(width: 1),
        const Expanded(child: _ChatArea()),
      ],
    ),
  );
}

void _mediumOpenChatFromDrawer(BuildContext drawerContext, String id) {
  drawerContext.read<ChatListCubit>().select(id);
  Scaffold.of(drawerContext).closeDrawer();
}

void _mediumRailDestinationSelected(BuildContext railContext, int index) {
  switch (index) {
    case 0:
      Scaffold.of(railContext).openDrawer();
    case 1:
      railContext.router.push(const HostsRoute());
    case 2:
      railContext.router.push(const SettingsRoute());
  }
}

class _MediumWorkspace extends StatelessWidget {
  const _MediumWorkspace();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      drawer: Builder(
        builder: (drawerContext) => Drawer(
          width: 320,
          child: SafeArea(
            child: _ChatListPanel(
              onOpen: (id) => _mediumOpenChatFromDrawer(drawerContext, id),
            ),
          ),
        ),
      ),
      body: Row(
        children: [
          Builder(
            builder: (railContext) => NavigationRail(
              selectedIndex: 0,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (index) =>
                  _mediumRailDestinationSelected(railContext, index),
              destinations: [
                NavigationRailDestination(
                  icon: const Icon(Icons.forum_outlined),
                  selectedIcon: const Icon(Icons.forum),
                  label: Text(l10n.navChats),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.dns_outlined),
                  label: Text(l10n.navHosts),
                ),
                NavigationRailDestination(
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(l10n.navSettings),
                ),
              ],
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
  Widget build(BuildContext context) => Scaffold(
    appBar: const _NavAppBar(),
    body: _ChatListPanel(
      onOpen: (id) => context.router.push(ChatRoute(chatId: id)),
    ),
  );
}

class _ChatArea extends StatelessWidget {
  const _ChatArea();

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<ChatListCubit, ChatListState>(
        buildWhen: (a, b) => a.selectedId != b.selectedId,
        builder: (context, state) => state.selectedId == null
            ? Center(child: Text(AppLocalizations.of(context).chatsSelectHint))
            : ChatView(chatId: state.selectedId!),
      );
}

class _NavAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _NavAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppBar(
      title: Text(l10n.navChats),
      actions: [
        IconButton(
          tooltip: l10n.navHosts,
          icon: const Icon(Icons.dns_outlined),
          onPressed: () => context.router.push(const HostsRoute()),
        ),
        IconButton(
          tooltip: l10n.navSettings,
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => context.router.push(const SettingsRoute()),
        ),
      ],
    );
  }
}

class _ChatListPanel extends StatelessWidget {
  const _ChatListPanel({required this.onOpen});

  final void Function(String chatId) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<ChatListCubit>();
    return BlocBuilder<ChatListCubit, ChatListState>(
      builder: (context, state) {
        final chats = state.visibleChats;
        final hostNames = {for (final host in state.hosts) host.id: host.name};
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.add),
                  label: Text(l10n.chatsNew),
                  onPressed: () async => onOpen(await cubit.create()),
                ),
              ),
            ),
            if (state.hosts.length > 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: Text(l10n.chatsFilterAll),
                      selected: state.hostFilter == null,
                      onSelected: (_) => cubit.setHostFilter(null),
                    ),
                    for (final host in state.hosts)
                      ChoiceChip(
                        label: Text(
                          host.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        selected: state.hostFilter == host.id,
                        onSelected: (_) => cubit.setHostFilter(host.id),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: chats.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          l10n.chatsEmpty,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final chat in chats)
                          _ChatTile(
                            chat: chat,
                            hostName: hostNames[chat.hostId],
                            selected: chat.id == state.selectedId,
                            running: state.runningIds.contains(chat.id),
                            waiting: state.waitingIds.contains(chat.id),
                            onTap: () => onOpen(chat.id),
                            onRename: () => _rename(context, chat),
                            onDelete: () => _delete(context, chat),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _rename(BuildContext context, Chat chat) async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: chat.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(l10n.commonRename),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title != null && context.mounted) {
      await context.read<ChatListCubit>().rename(chat.id, title);
    }
  }

  Future<void> _delete(BuildContext context, Chat chat) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(l10n.chatsDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<ChatListCubit>().delete(chat.id);
    }
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    required this.chat,
    required this.hostName,
    required this.selected,
    required this.running,
    required this.waiting,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Chat chat;
  final String? hostName;
  final bool selected;
  final bool running;
  final bool waiting;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      selected: selected,
      title: Text(
        chat.title.isEmpty ? l10n.chatsNew : chat.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: hostName == null
          ? null
          : Text(hostName!, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (waiting)
            Tooltip(
              message: l10n.chatBadgeWaiting,
              child: Icon(
                Icons.pan_tool_alt_outlined,
                size: 18,
                color: scheme.tertiary,
              ),
            ),
          if (running)
            Tooltip(
              message: l10n.chatBadgeRunning,
              child: const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz, size: 18),
            onSelected: (action) =>
                action == 'rename' ? onRename() : onDelete(),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'rename', child: Text(l10n.commonRename)),
              PopupMenuItem(value: 'delete', child: Text(l10n.commonDelete)),
            ],
          ),
        ],
      ),
    );
  }
}
