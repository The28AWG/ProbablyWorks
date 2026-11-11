import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/router/app_router.dart';

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.router.replace(
        WorkspaceRoute(profileId: getIt<ProfileService>().localProfileId),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
