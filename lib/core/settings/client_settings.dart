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
