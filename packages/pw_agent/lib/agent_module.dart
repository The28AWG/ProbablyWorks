import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/turn/turn_changeset_store.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/openrouter/openrouter_llm_provider.dart';

/// Ресурсы агента, которым нужны каталоги и секреты.
///
/// [AppPaths] и [SecretStore] регистрируются снаружи: клиентом или демоном.
@module
abstract class AgentCoreModule {
  @preResolve
  Future<AppDatabase> database(AppPaths paths) async =>
      openAppDatabase(paths.support);

  @singleton
  ExecLogStore execLogStore(AppPaths paths) => ExecLogStore(paths.root);

  @singleton
  TurnChangesetStore turnChangesetStore(AppPaths paths) =>
      TurnChangesetStore(paths.root);

  /// Ключ читается при каждом запросе: смена ключа в Settings действует сразу.
  @singleton
  LlmProvider llmProvider(SecretStore secrets) =>
      OpenRouterLlmProvider(apiKey: () => secrets.read(openRouterKeyName));
}
