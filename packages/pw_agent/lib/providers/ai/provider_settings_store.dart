import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llm_provider_meta.dart';

/// Общие ключи настроек провайдера в kv-таблице.
///
/// Схема одна для всех: `provider.<id>.enabled` и `provider.<id>.baseUrl`.
/// Ключ хранится отдельно, в `SecretStore`, под именем
/// [providerApiKeyName]. Новый провайдер не добавляет свои ключи в
/// [SettingsRepository] и не требует миграции схемы.
String providerSettingKey(String providerId, String field) =>
    'provider.$providerId.$field';

/// Старые ключи, которые читаются для существующих профилей.
///
/// Записываем всегда новые ключи, а старые удаляем при сохранении: иначе
/// после смены настройки чтение снова вернулось бы к прежнему значению.
const _legacySecrets = {
  'openrouter': openRouterKeyName,
  'llamacpp': llamaCppKeyName,
};

const _legacySettings = {
  'llamacpp': (
    enabled: SettingsRepository.keyLlamaCppEnabled,
    baseUrl: SettingsRepository.keyLlamaCppBaseUrl,
  ),
};

/// Читает и пишет настройки провайдеров по общим ключам.
///
/// Секреты не покидают этот класс: наружу отдаётся [LlmProviderStatus],
/// а полный ключ — только адаптеру через [LlmProviderConfig].
class LlmProviderSettingsStore {
  const LlmProviderSettingsStore(this._settings, this._secrets);

  final SettingsRepository _settings;
  final SecretStore _secrets;

  /// Текущие настройки провайдера. Незаданные поля получают значения
  /// по умолчанию из дескриптора.
  Future<LlmProviderConfig> read(LlmProviderDescriptor descriptor) async {
    final enabledValue = await _readSetting(descriptor, 'enabled');
    final baseUrlValue = await _readSetting(descriptor, 'baseUrl');
    final apiKey = await _readApiKey(descriptor);
    return LlmProviderConfig(
      enabled: enabledValue != 'false',
      baseUrl: baseUrlValue == null || baseUrlValue.trim().isEmpty
          ? descriptor.defaultBaseUrl
          : baseUrlValue.trim(),
      apiKey: apiKey,
    );
  }

  /// Статус без обращения к сети: только то, что записано в настройках.
  Future<LlmProviderStatus> readStatus(LlmProviderDescriptor descriptor) async {
    final config = await read(descriptor);
    return LlmProviderStatus(
      id: descriptor.id,
      enabled: config.enabled,
      baseUrl: config.baseUrl,
      apiKeySet: config.hasApiKey,
      apiKeyTail: config.apiKeyTail,
    );
  }

  /// Включает или выключает провайдера. Значение пишется явно, чтобы
  /// не провалиться обратно в старый ключ `llamaCpp.enabled`.
  Future<void> setEnabled(LlmProviderDescriptor descriptor, bool enabled) =>
      _writeSetting(descriptor, 'enabled', enabled ? 'true' : 'false');

  /// Сохраняет адрес сервера. Пустая строка возвращает значение по умолчанию.
  Future<void> saveBaseUrl(
    LlmProviderDescriptor descriptor,
    String? baseUrl,
  ) async {
    final value = baseUrl?.trim();
    await _writeSetting(
      descriptor,
      'baseUrl',
      value == null || value.isEmpty ? null : value,
    );
  }

  /// Сохраняет ключ. Пустой ключ не пишется: для удаления есть [deleteApiKey].
  Future<void> saveApiKey(LlmProviderDescriptor descriptor, String key) async {
    final value = key.trim();
    if (value.isEmpty) return;
    await _secrets.write(providerApiKeyName(descriptor.id), value);
    await _deleteLegacySecret(descriptor);
  }

  /// Удаляет ключ и из нового, и из старого места.
  Future<void> deleteApiKey(LlmProviderDescriptor descriptor) async {
    await _secrets.delete(providerApiKeyName(descriptor.id));
    await _deleteLegacySecret(descriptor);
  }

  /// Ключ из нового места, иначе из старого.
  Future<String?> _readApiKey(LlmProviderDescriptor descriptor) async {
    final value = await _secrets.read(providerApiKeyName(descriptor.id));
    if (value != null && value.isNotEmpty) return value;
    final legacy = _legacySecrets[descriptor.id];
    if (legacy == null) return null;
    return _secrets.read(legacy);
  }

  Future<String?> _readSetting(
    LlmProviderDescriptor descriptor,
    String field,
  ) async {
    final value = await _settings.read(
      providerSettingKey(descriptor.id, field),
    );
    if (value != null) return value;
    final legacy = _legacySettings[descriptor.id];
    if (legacy == null) return null;
    return _settings.read(field == 'enabled' ? legacy.enabled : legacy.baseUrl);
  }

  Future<void> _writeSetting(
    LlmProviderDescriptor descriptor,
    String field,
    String? value,
  ) async {
    await _settings.write(providerSettingKey(descriptor.id, field), value);
    final legacy = _legacySettings[descriptor.id];
    if (legacy == null) return;
    await _settings.write(
      field == 'enabled' ? legacy.enabled : legacy.baseUrl,
      null,
    );
  }

  Future<void> _deleteLegacySecret(LlmProviderDescriptor descriptor) async {
    final legacy = _legacySecrets[descriptor.id];
    if (legacy == null) return;
    await _secrets.delete(legacy);
  }
}
