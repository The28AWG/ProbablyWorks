/// Подключение к llama.cpp server и статус этого провайдера.
///
/// Пакет `llama_cpp` описывает HTTP-клиент; здесь живёт только то, что
/// относится к приложению: настройки, ключ в [SecretStore] и статус для UI.
library;

import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:llama_cpp/llama_cpp.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/core/util/text_clip.dart';

/// Префикс id моделей llama.cpp в общем каталоге.
///
/// OpenRouter id остаются без префикса, поэтому сохранённые модели и
/// существующие чаты продолжают работать без миграции.
const String llamaCppModelPrefix = 'llamacpp:';

/// Имя секрета с ключом llama.cpp server (необязателен).
const String llamaCppKeyName = 'llamacpp.apiKey';

/// Значение по умолчанию: адрес локального `llama-server`.
const String llamaCppDefaultBaseUrl = 'http://localhost:8080';

/// Признак модели llama.cpp по префиксу в общем каталоге.
bool isLlamaCppModel(String id) => id.startsWith(llamaCppModelPrefix);

/// Убирает префикс [llamaCppModelPrefix] из id модели.
String llamaCppModelId(String id) =>
    isLlamaCppModel(id) ? id.replaceFirst(llamaCppModelPrefix, '') : id;

/// Настройки подключения, прочитанные из [SettingsRepository] и [SecretStore].
class LlamaCppConnection extends Equatable {
  const LlamaCppConnection({
    this.enabled = true,
    this.baseUrl = llamaCppDefaultBaseUrl,
    this.apiKey,
  });

  /// Провайдер включён. Выключенный не опрашивается и не попадает в каталог.
  final bool enabled;

  /// Адрес сервера, например `http://localhost:8080`.
  final String baseUrl;

  /// Ключ доступа, если сервер запущен с `--api-key`.
  final String? apiKey;

  bool get hasApiKey => apiKey != null && apiKey!.isNotEmpty;

  /// Последние три символа ключа для маски в UI. Пусто — ключа нет.
  String get keyTail {
    final key = apiKey;
    if (key == null || key.isEmpty) return '';
    final runes = key.runes.toList();
    return String.fromCharCodes(
      runes.skip(runes.length > 3 ? runes.length - 3 : 0),
    );
  }

  @override
  List<Object?> get props => [enabled, baseUrl, apiKey];
}

/// Статус провайдера llama.cpp для экрана настроек.
///
/// Не содержит ключа: только признак, что он задан, и маску.
class LlamaCppStatus extends Equatable {
  const LlamaCppStatus({
    this.enabled = true,
    this.baseUrl = llamaCppDefaultBaseUrl,
    this.apiKeySet = false,
    this.apiKeyTail = '',
    this.available = false,
    this.modelCount,
    this.error,
    this.checkedAt,
  });

  /// Провайдер включён.
  final bool enabled;

  /// Адрес, который сейчас опрашивается.
  final String baseUrl;

  /// Ключ задан в [SecretStore].
  final bool apiKeySet;

  /// Последние три символа ключа для маски.
  final String apiKeyTail;

  /// Сервер ответил на health-запрос.
  final bool available;

  /// Сколько моделей вернул сервер в последней проверке.
  final int? modelCount;

  /// Причина последней неудачной проверки; null после успешной.
  final String? error;

  /// Время последней проверки.
  final DateTime? checkedAt;

  LlamaCppStatus copyWith({
    bool? enabled,
    String? baseUrl,
    bool? apiKeySet,
    String? apiKeyTail,
    bool? available,
    int? modelCount,
    String? error,
    bool clearError = false,
    DateTime? checkedAt,
  }) => LlamaCppStatus(
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKeySet: apiKeySet ?? this.apiKeySet,
    apiKeyTail: apiKeyTail ?? this.apiKeyTail,
    available: available ?? this.available,
    modelCount: modelCount ?? this.modelCount,
    error: clearError ? null : (error ?? this.error),
    checkedAt: checkedAt ?? this.checkedAt,
  );

  @override
  List<Object?> get props => [
    enabled,
    baseUrl,
    apiKeySet,
    apiKeyTail,
    available,
    modelCount,
    error,
    checkedAt,
  ];
}

/// Читает настройки llama.cpp из хранилища.
///
/// Вынесено в отдельный класс, чтобы адаптер, каталог и настройки
/// использовали одно и то же правило «пусто = значение по умолчанию».
class LlamaCppSettingsReader {
  const LlamaCppSettingsReader(this._settings, this._secrets);

  final SettingsRepository _settings;
  final SecretStore _secrets;

  Future<LlamaCppConnection> read() async {
    final enabled = await _settings.read(SettingsRepository.keyLlamaCppEnabled);
    final baseUrl = await _settings.read(SettingsRepository.keyLlamaCppBaseUrl);
    final apiKey = await _secrets.read(llamaCppKeyName);
    return LlamaCppConnection(
      enabled: enabled != 'false',
      baseUrl: baseUrl == null || baseUrl.trim().isEmpty
          ? llamaCppDefaultBaseUrl
          : baseUrl.trim(),
      apiKey: apiKey,
    );
  }

  /// Статус без обращения к серверу: только то, что записано в настройках.
  Future<LlamaCppStatus> readStatus() async {
    final connection = await read();
    return LlamaCppStatus(
      enabled: connection.enabled,
      baseUrl: connection.baseUrl,
      apiKeySet: connection.hasApiKey,
      apiKeyTail: connection.keyTail,
    );
  }
}

/// Провайдер, который умеет сообщать статус llama.cpp.
///
/// Каталог моделей проверяет, реализует ли [LlmProvider] этот интерфейс,
/// и тогда показывает состояние сервера в настройках. Тестовые провайдеры
/// могут его не реализовывать.
abstract interface class LlamaCppStatusProvider {
  /// Провайдер включён в настройках.
  Future<bool> get isEnabled;

  /// Сервер отвечает на health-запрос.
  Future<bool> get isAvailable;

  /// Проверка доступности и размера каталога без исключений.
  Future<LlamaCppStatus> checkHealth();
}

/// Ошибка llama.cpp → типизированная [LlmFailure].
///
/// Причина берётся из тела ответа, если сервер её прислал. Секреты
/// вырезаются, потому что тело может содержать ключ в заголовке.
LlmFailure llamaCppFailureOf(Object error) {
  if (error is LlmFailure) return error;
  if (error is LlamaCppException) {
    final status = error.statusCode;
    final detail = _serverDetail(error.body);
    final message = detail == null
        ? 'llama.cpp server error (HTTP $status)'
        : 'llama.cpp server error (HTTP $status): ${Redactor.redact(detail)}';
    final lower = message.toLowerCase();
    final contextExceeded =
        lower.contains('context') &&
        (lower.contains('length') || lower.contains('maximum'));
    return LlmFailure(
      message,
      statusCode: status,
      retryable: status == 429 || status >= 500,
      contextLengthExceeded: contextExceeded,
      modelNotFound: status == 404,
    );
  }
  return LlmFailure('$error');
}

/// Текст причины из JSON-тела ошибки. Если тело не JSON — берём его начало.
String? _serverDetail(String body) {
  if (body.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map && error['message'] is String) {
        return error['message'] as String;
      }
      if (error is String && error.isNotEmpty) return error;
      if (decoded['message'] is String) return decoded['message'] as String;
    }
  } on FormatException {
    return TextClip.headTail(
      body.replaceAll(RegExp(r'\s+'), ' ').trim(),
      maxChars: 160,
    );
  }
  return null;
}
