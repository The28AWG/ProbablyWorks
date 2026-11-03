import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/short_time.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Список чатов: создание, группы по дате, контекстное меню.
/// Используется в широком режиме постоянной панелью, в среднем — в drawer, в компактном — на весь экран.
class ChatListPanel extends StatelessWidget {
  const ChatListPanel({required this.onOpen, super.key});

  final void Function(String chatId) onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cubit = context.read<ChatListCubit>();
    return BlocBuilder<ChatListCubit, ChatListState>(
      // Смена выбранного чата не перестраивает весь список: подсветку обновляет только строка.
      buildWhen: (previous, current) =>
          previous.chats != current.chats ||
          previous.hosts != current.hosts ||
          previous.runningIds != current.runningIds ||
          previous.waitingIds != current.waitingIds,
      builder: (context, state) {
        final now = DateTime.now();
        final hosts = {for (final host in state.hosts) host.id: host};
        final chats = state.chats;
        final groups = {
          for (final bucket in DayBucket.values) bucket: <Chat>[],
        };
        for (final chat in chats) {
          groups[dayBucket(chat.updatedAt, now: now)]!.add(chat);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: Text(l10n.chatsNew),
                onPressed: () async => onOpen(await cubit.create()),
              ),
            ),
            Expanded(
              child: chats.isEmpty
                  ? AppEmptyState(
                      icon: Icons.forum_outlined,
                      title: l10n.chatsEmpty,
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                      children: [
                        for (final bucket in DayBucket.values)
                          if (groups[bucket]!.isNotEmpty) ...[
                            _GroupHeader(
                              title: switch (bucket) {
                                DayBucket.today => l10n.chatsGroupToday,
                                DayBucket.yesterday => l10n.chatsGroupYesterday,
                                DayBucket.earlier => l10n.chatsGroupEarlier,
                              },
                            ),
                            for (final chat in groups[bucket]!)
                              BlocSelector<ChatListCubit, ChatListState, bool>(
                                selector: (s) => s.selectedId == chat.id,
                                builder: (context, selected) => _ChatTile(
                                  chat: chat,
                                  now: now,
                                  host: hosts[chat.hostId],
                                  selected: selected,
                                  running: state.runningIds.contains(chat.id),
                                  waiting: state.waitingIds.contains(chat.id),
                                  onTap: () => onOpen(chat.id),
                                  onMenu: (position) =>
                                      _showChatMenu(context, chat, position),
                                ),
                              ),
                          ],
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

Future<void> _showChatMenu(
  BuildContext context,
  Chat chat,
  Offset position,
) async {
  final l10n = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  final action = await showMenu<_ChatAction>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    ),
    items: [
      PopupMenuItem(
        value: _ChatAction.rename,
        child: Row(
          children: [
            const Icon(Icons.edit_outlined, size: 18),
            const SizedBox(width: AppSpacing.sm),
            Text(l10n.commonRename),
          ],
        ),
      ),
      PopupMenuItem(
        value: _ChatAction.delete,
        child: Row(
          children: [
            Icon(Icons.delete_outline, size: 18, color: scheme.error),
            const SizedBox(width: AppSpacing.sm),
            Text(l10n.commonDelete, style: TextStyle(color: scheme.error)),
          ],
        ),
      ),
    ],
  );
  if (!context.mounted || action == null) return;
  switch (action) {
    case _ChatAction.rename:
      await _renameChat(context, chat);
    case _ChatAction.delete:
      await _deleteChat(context, chat);
  }
}

Future<void> _renameChat(BuildContext context, Chat chat) async {
  final l10n = AppLocalizations.of(context);
  final title = await ConfirmDialog.prompt(
    context,
    title: l10n.commonRename,
    cancelLabel: l10n.commonCancel,
    confirmLabel: l10n.commonRename,
    initialText: chat.title,
  );
  if (title != null && context.mounted) {
    await context.read<ChatListCubit>().rename(chat.id, title);
  }
}

Future<void> _deleteChat(BuildContext context, Chat chat) async {
  final l10n = AppLocalizations.of(context);
  final ok = await ConfirmDialog.confirm(
    context,
    title: l10n.commonDelete,
    message: l10n.chatsDeleteConfirm,
    cancelLabel: l10n.commonCancel,
    confirmLabel: l10n.commonDelete,
    destructive: true,
  );
  if (ok && context.mounted) {
    await context.read<ChatListCubit>().delete(chat.id);
  }
}

enum _ChatAction { rename, delete }

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.md,
      AppSpacing.lg,
      AppSpacing.xs,
    ),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );
}

class _ChatTile extends StatefulWidget {
  const _ChatTile({
    required this.chat,
    required this.now,
    required this.host,
    required this.selected,
    required this.running,
    required this.waiting,
    required this.onTap,
    required this.onMenu,
  });

  final Chat chat;
  final DateTime now;
  final Host? host;
  final bool selected;
  final bool running;
  final bool waiting;
  final VoidCallback onTap;
  final void Function(Offset position) onMenu;

  @override
  State<_ChatTile> createState() => _ChatTileState();
}

class _ChatTileState extends State<_ChatTile> {
  var _hovered = false;

  void _openRowMenuFromButton() {
    final box = context.findRenderObject()! as RenderBox;
    widget.onMenu(box.localToGlobal(box.size.bottomRight(Offset.zero)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chat = widget.chat;
    final host = widget.host;
    final hostName = host == null
        ? ''
        : (host.isLocal ? l10n.hostLocalName : host.name);
    final subtitle = [
      if (hostName.isNotEmpty) hostName,
      formatShortTime(chat.updatedAt, now: widget.now),
    ].join(' · ');
    final showMenuButton = _hovered || widget.selected || widget.waiting;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 2,
        ),
        child: Material(
          color: widget.selected
              ? scheme.secondaryContainer
              : Colors.transparent,
          borderRadius: AppRadius.mdAll,
          child: InkWell(
            borderRadius: AppRadius.mdAll,
            onTap: widget.onTap,
            onSecondaryTapDown: (details) =>
                widget.onMenu(details.globalPosition),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 8,
                    child: widget.waiting
                        ? const StatusDot(tone: AppTone.waiting)
                        : widget.running
                        ? const StatusDot(tone: AppTone.progress, pulse: true)
                        : null,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chat.title.isEmpty ? l10n.chatsNew : chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: widget.selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedOpacity(
                    duration: AppDurations.fast,
                    opacity: showMenuButton ? 1 : 0,
                    child: IconButton(
                      tooltip: l10n.commonMore,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.more_horiz, size: 18),
                      onPressed: _openRowMenuFromButton,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
