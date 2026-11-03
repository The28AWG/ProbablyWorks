import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:probably_works/app/router/app_router.dart';

/// Разделы оболочки. Порядок совпадает с вкладками [AutoTabsRouter].
enum WorkspaceTab { chats, hosts, settings }

/// Стек вкладки чатов. Вкладка создаётся при старте и живёт, пока открыта оболочка, поэтому стек есть всегда.
StackRouter? _chatsStack(TabsRouter tabs) =>
    tabs.stackRouterOfIndex(WorkspaceTab.chats.index);

/// Id чата, который открыт в стеке вкладки чатов. `null`, если открыт стартовый экран или другой раздел.
String? selectedChatIdOf(TabsRouter tabs) {
  final top = _chatsStack(tabs)?.topRoute;
  if (top == null || top.name != ChatRoute.name) return null;
  return top.params.getString('chatId');
}

/// Переключает раздел. Вкладка чатов сохраняет открытый чат, как и остальные вкладки.
void showWorkspaceTab(BuildContext context, WorkspaceTab tab) =>
    AutoTabsRouter.of(context).setActiveIndex(tab.index);

/// Открывает чат из списка или боковой панели. Стек вкладки чатов всегда содержит один экран: стартовый
/// экран или чат, поэтому новый выбор заменяет текущий, а не копится в истории.
void openChat(BuildContext context, String chatId) {
  final tabs = AutoTabsRouter.of(context);
  final stack = _chatsStack(tabs);
  if (stack == null) return;
  tabs.setActiveIndex(WorkspaceTab.chats.index);
  final top = stack.topRoute;
  if (top.name == ChatRoute.name && top.params.getString('chatId') == chatId) {
    return;
  }
  unawaited(stack.replace(ChatRoute(chatId: chatId)));
}

/// Стартовый экран нового чата. Чат появится в списке после первой отправки и откроется на этом же месте.
void openNewChat(BuildContext context) {
  final tabs = AutoTabsRouter.of(context);
  final stack = _chatsStack(tabs);
  if (stack == null) return;
  tabs.setActiveIndex(WorkspaceTab.chats.index);
  if (stack.topRoute.name == NewChatRoute.name) return;
  unawaited(stack.replace(const NewChatRoute()));
}
