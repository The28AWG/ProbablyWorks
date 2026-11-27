import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ключи клиентских настроек. Совпадают со старыми ключами kv, чтобы
/// миграция из БД агента не требовала преобразований.
abstract final class ClientSettingsKeys {
  static const language = 'language';
  static const themeMode = 'themeMode';
  static const sidebarWidth = 'sidebarWidth';
  static const agentProfiles = 'agentProfiles';
  static const localAgentProfileId = 'localAgentProfileId';
  static const keybindings = 'keybindings';

  /// Стабильный id установки для `X-Client-Id`.
  ///
  /// Не входит в [interfacePreferences]: сброс настроек интерфейса не должен
  /// выдавать текущее устройство за новое. На web ключ живёт в `localStorage`
  /// (через `shared_preferences`), поэтому дублированная вкладка его наследует,
  /// а другой профиль браузера получает свой.
  static const clientId = 'clientId';

  /// Порядок моделей в диалоге выбора: значение `ModelSort.name`.
  static const modelSort = 'modelSort';

  /// Время последней активности окна для дайджеста «пока вас не было».
  ///
  /// Хранится на устройстве: сколько приложение было закрыто или в фоне, знает
  /// только оно. Сами счётчики дайджеста приходят с сервера и общие для всех
  /// экранов.
  static const attentionDigestLastActiveAt = 'attentionDigestLastActiveAt';

  /// Показывать дайджест после долгого отсутствия. Отсутствие значения —
  /// включено; выключение хранится как `'false'`.
  static const attentionDigestEnabled = 'attentionDigestEnabled';

  /// Одноразовый перенос секретов GUI в keyring локального демона.
  static const daemonSecretsMigrated = 'daemonSecretsMigrated';

  /// Предпочтения интерфейса, которые возвращает к значениям по умолчанию
  /// сброс настроек. Подключения к агентам и их токены сюда не входят.
  static const interfacePreferences = <String>[
    language,
    themeMode,
    sidebarWidth,
    keybindings,
    modelSort,
    attentionDigestEnabled,
  ];
}

/// Настройки интерфейса и клиентского состояния, не принадлежащие агенту.
abstract interface class ClientSettings {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
}

/// `ClientSettings` поверх `shared_preferences`.
final class SharedPreferencesClientSettings implements ClientSettings {
  SharedPreferencesClientSettings(this._prefs);

  final SharedPreferencesAsync _prefs;

  @override
  Future<String?> read(String key) => _prefs.getString(key);

  @override
  Future<void> write(String key, String? value) =>
      value == null ? _prefs.remove(key) : _prefs.setString(key, value);
}

/// Хранилище в памяти для тестов и сценариев без платформенных настроек.
final class MemoryClientSettings implements ClientSettings {
  MemoryClientSettings([Map<String, String>? values]) : values = values ?? {};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

/// Однократно переносит старые клиентские ключи из БД агента.
///
/// В daemon-режиме этот код выполняется только при embedded-старте, когда
/// БД ещё доступна. Существующие значения в `ClientSettings` не затираются.
Future<void> migrateClientSettings(
  ClientSettings client,
  SettingsRepository agent,
) async {
  for (final key in const [
    ClientSettingsKeys.language,
    ClientSettingsKeys.themeMode,
    ClientSettingsKeys.sidebarWidth,
    ClientSettingsKeys.agentProfiles,
    ClientSettingsKeys.localAgentProfileId,
  ]) {
    if (await client.read(key) != null) continue;
    final value = await agent.read(key);
    if (value != null) await client.write(key, value);
  }
}
