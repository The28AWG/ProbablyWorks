import 'package:get_it/get_it.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/app/di/injection.config.dart';

final GetIt getIt = GetIt.instance;

/// Регистрация зависимостей. Генерируется build_runner: `dart run build_runner build`.
@InjectableInit(preferRelativeImports: true)
Future<void> configureDependencies() => getIt.init();
