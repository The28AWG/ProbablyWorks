import 'package:auto_route/auto_route.dart';
import 'package:probably_works/app/profiles/local_agent_apis.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/router/app_router.gr.dart';
import 'package:probably_works/core/platform/app_platform.dart';

/// Без настроенного LLM-провайдера локальный агент не работает: ведём на онбординг.
///
/// Проверяется не конкретный ключ OpenRouter, а наличие хотя бы одного
/// провайдера с нужными настройками. Проверка не трогает сеть: локальный
/// сервер может быть просто выключен, и это не повод блокировать интерфейс.
///
/// Удалённый профиль держит настройки у себя на сервере, поэтому локальная
/// проверка для его ветки не требуется. Проверка идёт только при входе
/// в ветку, а не при каждом переходе внутри неё.
class ApiKeyGuard extends AutoRouteGuard {
  ApiKeyGuard(this._profiles, this._local);

  final ProfileService _profiles;
  final LocalAgentApisProvider _local;

  /// Настроен ли хоть один провайдер. В embedded-режиме выставляется
  /// каталогом моделей после регистрации агентских зависимостей.
  Future<bool> Function() hasProvider = _noProvider;

  static Future<bool> _noProvider() async => false;

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
    if (await hasProvider()) {
      resolver.next();
    } else {
      resolver.redirectUntil(const OnboardingRoute());
    }
  }
}
