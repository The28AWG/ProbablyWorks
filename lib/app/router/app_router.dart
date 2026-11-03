import 'package:auto_route/auto_route.dart';
import 'package:probably_works/app/guards/api_key_guard.dart';
import 'package:probably_works/app/router/app_router.gr.dart';

export 'app_router.gr.dart';

@AutoRouterConfig(replaceInRouteName: 'Page,Route')
class AppRouter extends RootStackRouter {
  AppRouter({required this.apiKeyGuard});

  final ApiKeyGuard apiKeyGuard;

  @override
  List<AutoRoute> get routes => [
    AutoRoute(page: OnboardingRoute.page, path: '/onboarding'),
    AutoRoute(
      page: WorkspaceRoute.page,
      path: '/',
      initial: true,
      guards: [apiKeyGuard],
    ),
    AutoRoute(
      page: NewChatRoute.page,
      path: '/chats/new',
      guards: [apiKeyGuard],
    ),
    AutoRoute(
      page: ChatRoute.page,
      path: '/chats/:chatId',
      guards: [apiKeyGuard],
    ),
    AutoRoute(page: HostsRoute.page, path: '/hosts', guards: [apiKeyGuard]),
    AutoRoute(
      page: SettingsRoute.page,
      path: '/settings',
      guards: [apiKeyGuard],
    ),
  ];
}
