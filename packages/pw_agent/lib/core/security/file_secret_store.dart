import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pw_agent/core/security/file_permissions.dart';
import 'package:pw_agent/core/security/secret_store.dart';

/// Файловый fallback для headless-режима.
///
/// Значения лежат в JSON-файле `0600` внутри каталога приложения `0700`.
/// Ключи провайдеров и токен API можно переопределить переменными
/// окружения — так демон запускается на сервере без графической сессии
/// и без keyring.
final class FileSecretStore implements SecretStore {
  FileSecretStore(Directory support, {this.environment = const {}})
    : _file = File(p.join(support.path, 'secrets.json'));

  static const openRouterEnvironment = 'PROBABLY_WORKS_OPENROUTER_KEY';
  static const openRouterFallbackEnvironment = 'OPENROUTER_API_KEY';
  static const apiTokenEnvironment = 'PROBABLY_WORKS_API_TOKEN';

  final File _file;
  final Map<String, String> environment;

  @override
  SecretStoreKind get kind => SecretStoreKind.headlessFile;

  @override
  Future<String?> read(String key) async {
    final fromEnvironment = _environmentValue(key);
    if (fromEnvironment != null) return fromEnvironment;
    return (await _load())[key];
  }

  @override
  Future<void> write(String key, String value) async {
    final values = await _load();
    values[key] = value;
    await _save(values);
  }

  @override
  Future<void> delete(String key) async {
    final values = await _load();
    if (values.remove(key) == null) return;
    await _save(values);
  }

  String? _environmentValue(String key) =>
      secretFromEnvironment(key, environment);

  Future<Map<String, String>> _load() async {
    if (!_file.existsSync()) return {};
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is String) '${entry.key}': entry.value as String,
      };
    } on FormatException {
      return {};
    } on FileSystemException {
      return {};
    }
  }

  Future<void> _save(Map<String, String> values) async {
    await _file.parent.create(recursive: true);
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(jsonEncode(values), flush: true);
    FilePermissions.file(temp);
    await temp.rename(_file.path);
  }
}

/// Переопределения секретов переменными окружения.
///
/// Нужны для серверного запуска без GUI и keyring. Возвращает null, если
/// переменная не задана или пуста.
///
/// Для любого провайдера работает общее имя
/// `PROBABLY_WORKS_<ID>_KEY`, где id переведён в верхний регистр, а всё
/// кроме латинских букв и цифр заменено на `_`. OpenRouter дополнительно
/// читает старые имена, чтобы не ломать существующие запуски.
String? secretFromEnvironment(String key, Map<String, String> environment) {
  String? nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;
  if (key == apiTokenKey) {
    return nonEmpty(environment[FileSecretStore.apiTokenEnvironment]);
  }
  final providerId = providerIdFromApiKeyName(key);
  if (providerId != null) {
    final envName = _providerEnvironment(providerId);
    final value = nonEmpty(environment[envName]);
    if (value != null) return value;
    if (providerId == 'openrouter') {
      return nonEmpty(environment[FileSecretStore.openRouterEnvironment]) ??
          nonEmpty(environment[FileSecretStore.openRouterFallbackEnvironment]);
    }
    return null;
  }
  if (key == openRouterKeyName) {
    return nonEmpty(environment[FileSecretStore.openRouterEnvironment]) ??
        nonEmpty(environment[FileSecretStore.openRouterFallbackEnvironment]);
  }
  return null;
}

/// Имя переменной окружения для ключа провайдера.
String _providerEnvironment(String providerId) =>
    'PROBABLY_WORKS_${providerId.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '_')}_KEY';
