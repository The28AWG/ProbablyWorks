import 'package:auto_route/auto_route.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/app/router/app_router.gr.dart';
import 'package:pw_agent/core/security/secret_store.dart';

/// Без ключа OpenRouter приложение не работает: ведём на онбординг.
@lazySingleton
class ApiKeyGuard extends AutoRouteGuard {
  ApiKeyGuard(this._secrets);

  final SecretStore _secrets;

  @override
  Future<void> onNavigation(
    NavigationResolver resolver,
    StackRouter router,
  ) async {
    final key = await _secrets.read(openRouterKeyName);
    if (key != null && key.isNotEmpty) {
      resolver.next();
    } else {
      resolver.redirectUntil(const OnboardingRoute());
    }
  }
}
