import 'package:auto_route/auto_route.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';

/// Чат на узком экране: отдельный маршрут поверх списка.
@RoutePage()
class ChatPage extends StatelessWidget {
  const ChatPage({@PathParam('chatId') required this.chatId, super.key});

  final String chatId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: BackButton(onPressed: () => context.router.maybePop()),
    ),
    body: ChatView(chatId: chatId),
  );
}
