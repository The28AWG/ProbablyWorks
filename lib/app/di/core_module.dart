import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/exec/exec_log_store.dart';
import 'package:probably_works/app/bootstrap/app_paths.dart';
import 'package:probably_works/app/guards/api_key_guard.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/openrouter/openrouter_llm_provider.dart';

/// Внешние ресурсы и провайдеры, которые нельзя создать аннотацией класса.
@module
abstract class CoreModule {
  @preResolve
  Future<AppPaths> paths() => AppPaths.resolve();

  @preResolve
  Future<AppDatabase> database(AppPaths paths) async =>
      openAppDatabase(paths.support);

  @singleton
  FlutterSecureStorage get secureStorage => const FlutterSecureStorage();

  @singleton
  ExecLogStore execLogStore(AppPaths paths) => ExecLogStore(paths.root);

  /// Ключ читается при каждом запросе: смена ключа в Settings действует сразу.
  @singleton
  AppRouter appRouter(ApiKeyGuard guard) => AppRouter(apiKeyGuard: guard);

  @singleton
  LlmProvider llmProvider(SecretStore secrets) =>
      OpenRouterLlmProvider(apiKey: () => secrets.read(openRouterKeyName));
}
