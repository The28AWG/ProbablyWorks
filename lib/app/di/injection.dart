import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/app/di/injection.config.dart';
import 'package:pw_agent/agent_di.dart';

final GetIt getIt = GetIt.instance;

/// Регистрация зависимостей клиента и ядра агента.
///
/// `AppPaths` регистрируется до вызова: он нужен модулю агента для открытия БД.
@InjectableInit(preferRelativeImports: true)
Future<void> configureDependencies() async {
  getIt.init();
  await configureAgentDependencies();
}
