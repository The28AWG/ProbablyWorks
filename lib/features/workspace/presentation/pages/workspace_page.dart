import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/projects/presentation/bloc/projects_cubit.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';
import 'package:pw_agent/agent/loop/agent_hub.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';

/// Рабочая область: оболочка с вкладками «Чаты», «Хосты», «Настройки». Вкладки — вложенные маршруты,
/// поэтому выбранный чат — это путь маршрута, а не отдельное состояние экрана.
/// Раскладка (боковая панель, полоса иконок, drawer или нижняя навигация) выбирается по ширине окна в [WorkspaceShell].
@RoutePage()
class WorkspacePage extends StatelessWidget {
  const WorkspacePage({super.key});

  @override
  Widget build(BuildContext context) => MultiBlocProvider(
    providers: [
      BlocProvider(
        create: (_) => ChatListCubit(
          getIt<AgentHub>(),
          getIt<ChatDraftStore>(),
          initialHosts: getIt<StartupHosts>().value,
        ),
      ),
      BlocProvider(
        create: (_) =>
            ProjectsCubit(getIt<ProjectRepository>(), getIt<HostRepository>()),
      ),
      BlocProvider(
        create: (_) => SidebarCubit(
          getIt<SettingsRepository>(),
          getIt<SidebarStartupWidth>().value,
        ),
      ),
    ],
    child: AutoTabsRouter(
      routes: [
        ChatsTabRoute(),
        ProjectsTabRoute(),
        HostsRoute(),
        SettingsRoute(),
      ],
      builder: (context, child) => WorkspaceShell(child: child),
    ),
  );
}
