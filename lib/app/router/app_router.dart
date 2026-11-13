import 'package:auto_route/auto_route.dart';
import 'package:probably_works/app/guards/api_key_guard.dart';
import 'package:probably_works/app/router/app_router.gr.dart';

export 'app_router.gr.dart';

/// Маршруты: оболочка рабочей области с вкладками. Вкладка чатов держит один экран: стартовый экран нового чата
/// или открытый чат. Список чатов живёт в панели оболочки. Хосты и настройки — отдельные вкладки той же оболочки.
@AutoRouterConfig(replaceInRouteName: 'Page,Route')
class AppRouter extends RootStackRouter {
  AppRouter({required this.apiKeyGuard});

  final ApiKeyGuard apiKeyGuard;

  @override
  List<AutoRoute> get routes => [
    AutoRoute(page: StartRoute.page, path: '/', initial: true),
    AutoRoute(page: OnboardingRoute.page, path: '/onboarding'),
    AutoRoute(page: WebConnectRoute.page, path: '/connect'),
    AutoRoute(
      page: WorkspaceRoute.page,
      path: '/a/:profileId',
      guards: [apiKeyGuard],
      children: [
        AutoRoute(
          page: ChatsTabRoute.page,
          path: 'chats',
          initial: true,
          children: [
            AutoRoute(page: NewChatRoute.page, path: '', initial: true),
            AutoRoute(page: ChatRoute.page, path: ':chatId'),
          ],
        ),
        AutoRoute(
          page: ProjectsTabRoute.page,
          path: 'projects',
          children: [
            AutoRoute(page: ProjectsRoute.page, path: '', initial: true),
            AutoRoute(page: ProjectRoute.page, path: ':projectId'),
          ],
        ),
        AutoRoute(page: HostsRoute.page, path: 'hosts'),
        AutoRoute(page: SettingsRoute.page, path: 'settings/:group'),
      ],
    ),
    // Неизвестный или неразобранный URL (например, хвостовой `/` после
    // браузерного обновления) не должен ронять приложение. StartPage
    // восстановит профиль или покажет подключение.
    RedirectRoute(path: '*', redirectTo: '/'),
  ];
}

/// Убирает хвостовой `/` и пустой `?` из deep link.
///
/// Браузер после перехода на `/settings/` может отдать `/settings/?`;
/// auto_route не матчит такой путь и падает с «Can not resolve initial route».
Future<Uri> normalizeAppDeepLink(Uri uri) async {
  var text = uri.toString();
  text = text.replaceFirst(RegExp(r'/\?'), '?');
  text = text.replaceFirst(RegExp(r'\?$'), '');
  if (text != '/') text = text.replaceFirst(RegExp(r'/+$'), '');
  return Uri.parse(text);
}
