import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/notifications/unread_badge_sync.dart';
import 'package:probably_works/app/profiles/agent_profile.dart';
import 'package:probably_works/app/profiles/profile_scope.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/palette/presentation/command_palette_host.dart';
import 'package:probably_works/features/projects/presentation/bloc/projects_cubit.dart';
import 'package:probably_works/features/workspace/presentation/bloc/sidebar_cubit.dart';
import 'package:probably_works/features/workspace/presentation/widgets/presence_lifecycle.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';

/// Рабочая область: оболочка с вкладками «Чаты», «Хосты», «Настройки». Вкладки — вложенные маршруты,
/// поэтому выбранный чат — это путь маршрута, а не отдельное состояние экрана.
/// Раскладка (боковая панель, полоса иконок, drawer или нижняя навигация) выбирается по ширине окна в [WorkspaceShell].
@RoutePage()
class WorkspacePage extends StatelessWidget {
  const WorkspacePage({
    @PathParam('profileId') required this.profileId,
    super.key,
  });

  final String profileId;

  @override
  Widget build(BuildContext context) {
    final service = getIt<ProfileService>();
    final profile = service.byId(profileId) ?? AgentProfile.local();
    final agentApi = service.agentApiFor(profile);
    final chatApi = service.chatApiFor(profile);
    getIt<ChatDraftStore>().bind(chatApi.chatStore);
    return ProfileScope(
      profile: profile,
      agentApi: agentApi,
      chatApi: chatApi,
      dataApi: service.dataApiFor(profile),
      hostsApi: service.hostsApiFor(profile),
      projectsApi: service.projectsApiFor(profile),
      settingsApi: service.settingsApiFor(profile),
      mcpApi: service.mcpApiFor(profile),
      pluginApi: service.pluginApiFor(profile),
      securityAuditApi: service.securityAuditApiFor(profile),
      pushApi: service.pushApiFor(profile),
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            create: (_) => ChatListCubit(
              agentApi,
              getIt<ChatDraftStore>(),
              initialHosts: profile.isLocal
                  ? getIt<StartupHosts>().value
                  : const [],
              chatApi: chatApi,
            ),
          ),
          BlocProvider(
            create: (_) => ProjectsCubit(
              service.projectsApiFor(profile),
              initialStatus: agentApi.status,
              statusChanges: agentApi.statusChanges,
            ),
          ),
          BlocProvider(
            create: (_) => SidebarCubit(
              getIt<ClientSettings>(),
              getIt<SidebarStartupWidth>().value,
            ),
          ),
        ],
        child: UnreadBadgeSync(
          child: AutoTabsRouter(
            routes: workspaceTabRoutes(agentApi.status),
            builder: (context, child) => PresenceLifecycle(
              tabs: AutoTabsRouter.of(context),
              sessionApi: _sessionApi(agentApi),
              child: CommandPaletteHost(child: WorkspaceShell(child: child)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Вкладки оболочки в порядке [WorkspaceTab].
///
/// Список вынесен из `build`, чтобы порядок маршрутов и индексы
/// [WorkspaceTab] проверялись тестом: расхождение открывает не тот раздел и
/// выходит за границы списка.
List<PageRouteInfo> workspaceTabRoutes(AgentStatus status) => [
  const ChatsTabRoute(),
  const InboxRoute(),
  const ProjectsTabRoute(),
  const HostsRoute(),
  SettingsRoute(
    initialGroup: status == AgentStatus.offline ? 'agents' : 'account',
  ),
];

ClientSessionApi? _sessionApi(AgentApi api) {
  final Object value = api;
  return value is ClientSessionApi ? value : null;
}
