import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:probably_works/app/router/app_router.dart';

/// Разделы оболочки. Порядок совпадает с вкладками [AutoTabsRouter].
enum WorkspaceTab { chats, projects, hosts, settings }

/// Стек вкладки чатов. Вкладка создаётся при старте и живёт, пока открыта оболочка, поэтому стек есть всегда.
StackRouter? _chatsStack(TabsRouter tabs) =>
    tabs.stackRouterOfIndex(WorkspaceTab.chats.index);

/// Стек вкладки проектов: список и карточка проекта.
StackRouter? _projectsStack(TabsRouter tabs) =>
    tabs.stackRouterOfIndex(WorkspaceTab.projects.index);

/// Id чата, который открыт в стеке вкладки чатов. `null`, если открыт стартовый экран или другой раздел.
String? selectedChatIdOf(TabsRouter tabs) {
  final top = _chatsStack(tabs)?.topRoute;
  if (top == null || top.name != ChatRoute.name) return null;
  return top.params.getString('chatId');
}

/// Id проекта, открытого в стеке вкладки проектов. `null`, если открыт список или другой раздел.
String? selectedProjectIdOf(TabsRouter tabs) {
  final top = _projectsStack(tabs)?.topRoute;
  if (top == null || top.name != ProjectRoute.name) return null;
  return top.params.getString('projectId');
}

/// Переключает раздел. Вкладка чатов сохраняет открытый чат, как и остальные вкладки.
void showWorkspaceTab(BuildContext context, WorkspaceTab tab) =>
    AutoTabsRouter.of(context).setActiveIndex(tab.index);

/// Открывает чат из списка или боковой панели. Стек вкладки чатов всегда содержит один экран: стартовый
/// экран или чат, поэтому новый выбор заменяет текущий, а не копится в истории.
void openChat(BuildContext context, String chatId, {String? messageId}) {
  final tabs = AutoTabsRouter.of(context);
  final stack = _chatsStack(tabs);
  if (stack == null) return;
  tabs.setActiveIndex(WorkspaceTab.chats.index);
  final top = stack.topRoute;
  if (messageId == null &&
      top.name == ChatRoute.name &&
      top.params.getString('chatId') == chatId) {
    return;
  }
  unawaited(stack.replace(ChatRoute(chatId: chatId, messageId: messageId)));
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

/// Открывает карточку проекта из чата или списка. Стек вкладки проектов пересобирается:
/// список остаётся под карточкой, поэтому «назад» возвращает к проектам.
///
/// Вкладка проектов создаётся лениво: при первом переходе её стек появляется
/// только после кадра. Раньше в этом случае функция молча выходила, и команда
/// «Память проекта» ничего не делала.
void openProject(BuildContext context, String projectId) {
  final tabs = AutoTabsRouter.of(context)
    ..setActiveIndex(WorkspaceTab.projects.index);
  if (_replaceProject(tabs, projectId)) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    _replaceProject(tabs, projectId);
  });
}

/// Пересобирает стек вкладки проектов. Возвращает false, если вкладка ещё не
/// построена и стек появится позже.
bool _replaceProject(TabsRouter tabs, String projectId) {
  final stack = _projectsStack(tabs);
  if (stack == null) return false;
  final top = stack.topRoute;
  if (top.name == ProjectRoute.name &&
      top.params.getString('projectId') == projectId) {
    return true;
  }
  unawaited(
    stack.replaceAll([
      const ProjectsRoute(),
      ProjectRoute(projectId: projectId),
    ]),
  );
  return true;
}
