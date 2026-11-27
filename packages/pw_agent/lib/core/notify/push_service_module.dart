import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/state/domain_change_bus.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/notify/push_service.dart';
import 'package:pw_agent/core/security/secret_store.dart';

/// Регистрирует [PushService] как singleton.
///
/// Сервису нужен счётчик непрочитанного из [ChatRepository]: payload push
/// должен нести то же число, что и открытые окна. Конструктор сам создаёт
/// HTTP-клиент, поэтому зависимость собирается здесь, а не аннотацией класса.
@module
abstract class PushServiceModule {
  @lazySingleton
  PushService pushService(
    SettingsRepository settings,
    SecretStore secrets,
    ChatRepository chats,
    DomainChangeBus changes,
  ) => PushService(settings, secrets, chats, changes: changes);
}
