import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/short_time.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Высота липкого заголовка группы: отступ сверху отделяет группы, текст стоит у низа.
const _groupHeaderExtent = AppSpacing.xxl + AppSpacing.sm;

/// Общий левый край списка: текст заголовков и названий совпадает с подписями навигации.
const _listInset = AppSpacing.sm + AppSpacing.md;

/// Список чатов по группам «сегодня / вчера / раньше» с контекстным меню.
/// Создание чата и навигация живут в оболочке (боковая панель, компактный экран).
class ChatListPanel extends StatelessWidget {
  const ChatListPanel({
    required this.onOpen,
    this.selectedId,
    this.onDeleted,
    this.background,
    super.key,
  });

  final void Function(String chatId) onOpen;

  /// Открытый сейчас чат: его строка выделена. Выбор приходит из маршрута, не из состояния списка.
  final String? selectedId;

  /// Чат удалён. Владелец экрана уходит с него, если он был открыт.
  final void Function(String chatId)? onDeleted;

  /// Фон липких заголовков: совпадает с фоном панели, на которой стоит список.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final headerBackground = background ?? scheme.surface;
    return BlocBuilder<ChatListCubit, ChatListState>(
      buildWhen: (previous, current) =>
          previous.chats != current.chats ||
          previous.hosts != current.hosts ||
          previous.runningIds != current.runningIds ||
          previous.waitingIds != current.waitingIds,
      builder: (context, state) {
        if (state.chats.isEmpty) {
          return AppEmptyState(
            icon: Icons.forum_outlined,
            title: l10n.chatsEmpty,
          );
        }
        final now = DateTime.now();
        final hosts = {for (final host in state.hosts) host.id: host};
        final groups = {
          for (final bucket in DayBucket.values) bucket: <Chat>[],
        };
        for (final chat in state.chats) {
          groups[dayBucket(chat.updatedAt, now: now)]!.add(chat);
        }
        return CustomScrollView(
          slivers: [
            for (final bucket in DayBucket.values)
              if (groups[bucket]!.isNotEmpty)
                SliverMainAxisGroup(
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _GroupHeaderDelegate(
                        title: switch (bucket) {
                          DayBucket.today => l10n.chatsGroupToday,
                          DayBucket.yesterday => l10n.chatsGroupYesterday,
                          DayBucket.earlier => l10n.chatsGroupEarlier,
                        },
                        background: headerBackground,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    SliverList.builder(
                      itemCount: groups[bucket]!.length,
                      itemBuilder: (context, index) {
                        final chat = groups[bucket]![index];
                        return _ChatTile(
                          chat: chat,
                          host: hosts[chat.hostId],
                          selected: chat.id == selectedId,
                          running: state.runningIds.contains(chat.id),
                          waiting: state.waitingIds.contains(chat.id),
                          onTap: () => onOpen(chat.id),
                          onMenu: (position) => _showChatMenu(
                            context,
                            chat,
                            position,
                            onDeleted: onDeleted,
                          ),
                        );
                      },
                    ),
                  ],
                ),
            SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
          ],
        );
      },
    );
  }
}

Future<void> _showChatMenu(
  BuildContext context,
  Chat chat,
  Offset position, {
  void Function(String chatId)? onDeleted,
}) async {
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
      await _deleteChat(context, chat, onDeleted: onDeleted);
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

Future<void> _deleteChat(
  BuildContext context,
  Chat chat, {
  void Function(String chatId)? onDeleted,
}) async {
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
    onDeleted?.call(chat.id);
  }
}

enum _ChatAction { rename, delete }

/// Заголовок группы, который остаётся у верхнего края списка при прокрутке.
class _GroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _GroupHeaderDelegate({
    required this.title,
    required this.background,
    required this.color,
  });

  final String title;
  final Color background;
  final Color color;

  @override
  double get minExtent => _groupHeaderExtent;

  @override
  double get maxExtent => _groupHeaderExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ColoredBox(
    color: background,
    child: Align(
      alignment: AlignmentDirectional.bottomStart,
      child: Padding(
        padding: const EdgeInsets.only(left: _listInset, bottom: AppSpacing.xs),
        child: Text(
          title,
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: color),
        ),
      ),
    ),
  );

  @override
  bool shouldRebuild(covariant _GroupHeaderDelegate oldDelegate) =>
      title != oldDelegate.title ||
      background != oldDelegate.background ||
      color != oldDelegate.color;
}

/// Строка чата: одна строка названия. Справа — статус активного чата, а при наведении или фокусе
/// вместо него кнопка меню.
class _ChatTile extends StatefulWidget {
  const _ChatTile({
    required this.chat,
    required this.host,
    required this.selected,
    required this.running,
    required this.waiting,
    required this.onTap,
    required this.onMenu,
  });

  final Chat chat;
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
  var _rowFocused = false;
  var _menuFocused = false;
  final _menuFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Фокус на кнопке меню с клавиатуры должен показывать её так же, как наведение мыши.
    _menuFocus.addListener(
      () => setState(() => _menuFocused = _menuFocus.hasFocus),
    );
  }

  @override
  void dispose() {
    _menuFocus.dispose();
    super.dispose();
  }

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
        ? null
        : (host.isLocal ? l10n.hostLocalName : host.name);
    final hostIcon = host == null || !host.isLocal
        ? Icons.dns_outlined
        : Icons.computer_outlined;
    final showMenu = _hovered || _rowFocused || _menuFocused;
    final active = widget.waiting || widget.running;
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
              ? scheme.surfaceContainerHighest
              : Colors.transparent,
          borderRadius: AppRadius.mdAll,
          child: InkWell(
            borderRadius: AppRadius.mdAll,
            onTap: widget.onTap,
            onFocusChange: (focused) => setState(() => _rowFocused = focused),
            onSecondaryTapDown: (details) =>
                widget.onMenu(details.globalPosition),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.xs,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          chat.title.isEmpty ? l10n.chatsNew : chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: widget.selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        if (hostName != null) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                hostIcon,
                                size: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Flexible(
                                child: Text(
                                  hostName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(
                    width: AppSpacing.xxl,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (active && !showMenu)
                          StatusDot(
                            tone: widget.waiting
                                ? AppTone.waiting
                                : AppTone.progress,
                            pulse: !widget.waiting,
                          ),
                        AnimatedOpacity(
                          duration: AppDurations.fast,
                          opacity: showMenu ? 1 : 0,
                          child: IconButton(
                            focusNode: _menuFocus,
                            tooltip: l10n.commonMore,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.more_horiz, size: 18),
                            onPressed: _openRowMenuFromButton,
                          ),
                        ),
                      ],
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
