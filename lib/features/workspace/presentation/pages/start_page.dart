import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/core/platform/app_platform.dart';

/// Стартовый маршрут `/`: ведёт на ветку локального профиля.
///
/// Идентификатор локального профиля создаётся один раз и хранится в
/// настройках, поэтому адрес всегда `/a/<id>/...` без особых префиксов.
@RoutePage()
class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (AppPlatform.current.isWeb) {
        final service = getIt<ProfileService>();
        final remote = service.profiles
            .where((profile) => !profile.isLocal)
            .firstOrNull;
        if (remote == null) {
          context.router.replace(const WebConnectRoute());
          return;
        }
        // Профиль не скрываем и не блокируем вход из-за offline:
        // внутри workspace будет уведомление, а в настройках можно
        // добавить другой профиль и переключиться.
        context.router.replace(WorkspaceRoute(profileId: remote.id));
        return;
      }
      context.router.replace(
        WorkspaceRoute(profileId: getIt<ProfileService>().localProfileId),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
