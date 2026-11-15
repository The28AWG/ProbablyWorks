import 'package:probably_works/app/di/injection.dart';
import 'package:pw_agent/providers/ai/llamadart/local_models_service.dart';

/// Освобождает нативные модели перед выходом.
///
/// В режиме клиента демона агентских зависимостей в этом процессе нет:
/// проверка регистрации не даёт создать сервис ради остановки.
Future<void> shutdownLocalEngine() async {
  if (getIt.isRegistered<LocalModelsService>()) {
    await getIt<LocalModelsService>().shutdown();
  }
}
