import 'package:get_it/get_it.dart';

/// Глобальный контейнер. На web сюда регистрирует только удалённые сервисы
/// `web_bootstrap`, без БД и локального агента.
final GetIt getIt = GetIt.instance;
