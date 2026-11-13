import 'package:auto_route/auto_route.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/app/profiles/local_agent_apis.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/router/app_router.gr.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:pw_agent/core/security/secret_store.dart';

/// Без ключа OpenRouter локальный агент не работает: ведём на онбординг.
///
/// Удалённый профиль держит ключ у себя на сервере, поэтому локальный ключ
/// для его ветки не требуется. Проверка идёт только при входе в ветку, а не
/// при каждом переходе внутри неё.
@lazySingleton
class ApiKeyGuard extends AutoRouteGuard {
  ApiKeyGuard(this._secrets, this._profiles, this._local);

  final SecretStore _secrets;
  final ProfileService _profiles;
  final LocalAgentApisProvider _local;

  @override
  Future<void> onNavigation(
    NavigationResolver resolver,
    StackRouter router,
  ) async {
    final args = resolver.route.args;
    // При deep link args может быть ещё не собран, но id всегда есть в
    // pathParams. Берём его оттуда, иначе после refresh профиль «теряется».
    final profileId = args is WorkspaceRouteArgs
        ? args.profileId
        : resolver.route.params.optString('profileId');
    final profile = profileId == null ? null : _profiles.byId(profileId);
    final localDaemon = _local.modeOrNull == LocalRuntimeMode.localDaemon;
    if (profile != null && (!profile.isLocal || localDaemon)) {
      resolver.next();
      return;
    }
    // В web локального агента нет: неизвестный профиль ведёт на подключение,
    // а не на нативный онбординг с ModelCatalogService и БД.
    if (AppPlatform.current.isWeb) {
      resolver.redirectUntil(const WebConnectRoute());
      return;
    }
    final key = await _secrets.read(openRouterKeyName);
    if (key != null && key.isNotEmpty) {
      resolver.next();
    } else {
      resolver.redirectUntil(const OnboardingRoute());
    }
  }
}
