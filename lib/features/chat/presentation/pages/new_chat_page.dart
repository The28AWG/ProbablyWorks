import 'package:auto_route/auto_route.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';

/// Новый чат на узком экране: стартовый экран, чат создаётся при первой отправке и открывается на месте.
@RoutePage()
class NewChatPage extends StatelessWidget {
  const NewChatPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ChatView(
        leading: BackButton(onPressed: () => context.router.maybePop()),
        onCreated: (chatId) =>
            context.router.replace(ChatRoute(chatId: chatId)),
      ),
    ),
  );
}
