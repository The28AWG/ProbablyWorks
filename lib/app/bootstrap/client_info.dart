import 'package:package_info_plus/package_info_plus.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:probably_works/core/settings/client_id_lock.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:uuid/uuid.dart';

/// Сведения о клиенте из `package_info`. Общая для обычного старта приложения
/// и фонового запуска планировщика. Ошибка чтения не критична: заголовки
/// удалённого API получат запасные значения.
///
/// [settings] даёт стабильный `clientId` установки. Он хранится отдельно от
/// `sessionId`: переживает перезапуск и обновление приложения, а на web лежит
/// в `localStorage` (`shared_preferences`), поэтому дублированная вкладка его
/// наследует. Без настроек id не сохраняется и остаётся пустым.
Future<ClientInfo> loadClientInfo({ClientSettings? settings}) async {
  final clientId = settings == null ? null : await ensureClientId(settings);
  try {
    return ClientInfo.fromPackageInfo(
      await PackageInfo.fromPlatform(),
      clientId: clientId,
    );
  } on Object catch (error) {
    AppLog.root.warning('cannot read package info', error);
    return ClientInfo.fallback(clientId: clientId);
  }
}

/// Читает стабильный id установки или создаёт его один раз.
///
/// Создание идёт под общей блокировкой: две вкладки web-клиента с пустым
/// хранилищем не должны выдать разные id одному устройству.
///
/// Ошибка хранилища не должна мешать запуску: тогда возвращается null и сервер
/// группирует сессии по отпечатку `X-Client-*`, как до появления `clientId`.
Future<String?> ensureClientId(ClientSettings settings) async {
  try {
    String? clientId;
    await withClientIdLock(() async {
      final stored = await settings.read(ClientSettingsKeys.clientId);
      if (stored != null && stored.isNotEmpty) {
        clientId = stored;
        return;
      }
      final created = const Uuid().v4();
      await settings.write(ClientSettingsKeys.clientId, created);
      clientId = created;
    });
    return clientId;
  } on Object catch (error) {
    AppLog.root.warning('cannot store client id', error);
    return null;
  }
}
