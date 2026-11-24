import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Открытый чат. Маршрут — вложенный в вкладку чатов, поэтому раскладка окна на него не влияет:
/// на узком экране в шапке кнопка меню, на широком чат показывается справа от панели.
@RoutePage()
class ChatPage extends StatefulWidget {
  const ChatPage({
    @PathParam('chatId') required this.chatId,
    @QueryParam('message') this.messageId,
    super.key,
  });

  final String chatId;

  /// Сообщение, к которому нужно прокрутить ленту. Null — открыть чат как обычно.
  final String? messageId;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  @override
  Widget build(BuildContext context) {
    // Чат из уже загруженного списка показываем сразу: шапка и композер без ожидания БД.
    final list = context.read<ChatListCubit>().state;
    return Scaffold(
      body: SafeArea(
        child: ChatView(
          chatId: widget.chatId,
          jumpToMessageId: widget.messageId,
          seedChat: list.chats
              .where((chat) => chat.id == widget.chatId)
              .firstOrNull,
          seedHosts: list.hosts,
          onCreated: (id) =>
              unawaited(context.router.push(ChatRoute(chatId: id))),
          onChatDeleted: _handleChatDeleted,
          leading: context.workspaceLayout == .compact
              ? const WorkspaceLeadingButton()
              : null,
        ),
      ),
    );
  }

  /// Уводит стек с удалённого чата, если открыт именно он. Экран этого чата
  /// мог остаться в фоне, например под дублем: закрывать видимый чат в ответ
  /// на удаление соседнего нельзя.
  ///
  /// Замена маршрута одновременно очищает `activeChatId` в присутствии.
  /// Активный раздел не переключаем: удаление в другом окне не должно
  /// выдёргивать пользователя из настроек. Сообщение объясняет, почему экран
  /// вернулся к новому чату.
  void _handleChatDeleted() {
    if (!mounted) return;
    final tabs = AutoTabsRouter.of(context);
    if (selectedChatIdOf(tabs) != widget.chatId) return;
    resetOpenChat(context);
    AppSnackBar.show(context, AppLocalizations.of(context).chatsDeleted);
  }
}
