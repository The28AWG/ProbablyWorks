import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';

/// Открытый чат. Маршрут — вложенный в вкладку чатов, поэтому раскладка окна на него не влияет:
/// на узком экране в шапке кнопка меню, на широком чат показывается справа от панели.
@RoutePage()
class ChatPage extends StatelessWidget {
  const ChatPage({
    @PathParam('chatId') required this.chatId,
    @QueryParam('message') this.messageId,
    super.key,
  });

  final String chatId;

  /// Сообщение, к которому нужно прокрутить ленту. Null — открыть чат как обычно.
  final String? messageId;

  @override
  Widget build(BuildContext context) {
    // Чат из уже загруженного списка показываем сразу: шапка и композер без ожидания БД.
    final list = context.read<ChatListCubit>().state;
    return Scaffold(
      body: SafeArea(
        child: ChatView(
          chatId: chatId,
          jumpToMessageId: messageId,
          seedChat: list.chats.where((chat) => chat.id == chatId).firstOrNull,
          seedHosts: list.hosts,
          onCreated: (id) =>
              unawaited(context.router.push(ChatRoute(chatId: id))),
          leading: context.workspaceLayout == .compact
              ? const WorkspaceLeadingButton()
              : null,
        ),
      ),
    );
  }
}
