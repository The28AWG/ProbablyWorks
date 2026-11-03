import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';

/// Стартовый экран нового чата. Чат создаётся при первой отправке и заменяет этот экран на месте.
@RoutePage()
class NewChatPage extends StatelessWidget {
  const NewChatPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ChatView(
        seedHosts: context.read<ChatListCubit>().state.hosts,
        leading: context.workspaceLayout == .compact
            ? const WorkspaceLeadingButton()
            : null,
        onCreated: (chatId) => _openCreatedChat(context, chatId),
      ),
    ),
  );

  void _openCreatedChat(BuildContext context, String chatId) {
    // Отправка идёт в фоне: экран мог уже закрыться, тогда открывать чат на его месте не нужно.
    if (!context.mounted) return;
    unawaited(context.router.replace(ChatRoute(chatId: chatId)));
  }
}
