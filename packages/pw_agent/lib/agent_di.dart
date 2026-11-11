import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent_di.config.dart';

final GetIt getIt = GetIt.instance;

/// Регистрация зависимостей ядра агента.
///
/// До вызова должны быть зарегистрированы [AppPaths], [SecretStore],
/// [AppNotifier], [AppearancePort], [ExternalUrlOpener] и [PluginRegistry]:
/// клиент делает это своими Flutter-реализациями, демон — headless-версиями.
@InjectableInit(initializerName: 'initAgent', preferRelativeImports: true)
Future<void> configureAgentDependencies() => getIt.initAgent();
