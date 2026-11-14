/// Подключение к llama.cpp server: дескриптор провайдера и разбор ошибок.
///
/// Пакет `llama_cpp` описывает HTTP-клиент; настройки хранит общий
/// `LlmProviderSettingsStore`, поэтому здесь нет собственного reader'а.
library;

import 'dart:convert';

import 'package:llama_cpp/llama_cpp.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/core/util/text_clip.dart';
import 'package:pw_agent/providers/ai/llm_provider_meta.dart';

/// Стабильный id провайдера в настройках и API.
const String llamaCppProviderId = 'llamacpp';

/// Префикс id моделей llama.cpp в общем каталоге.
///
/// OpenRouter id остаются без префикса, поэтому сохранённые модели и
/// существующие чаты продолжают работать без миграции.
const String llamaCppModelPrefix = 'llamacpp:';

/// Старое имя секрета. Читается для существующих профилей, новые ключи
/// пишутся в `provider.llamacpp.apiKey`.
const String llamaCppKeyName = 'llamacpp.apiKey';

/// Значение по умолчанию: адрес локального `llama-server`.
const String llamaCppDefaultBaseUrl = 'http://localhost:8080';

/// Описание провайдера для каталога и интерфейса.
const llamaCppDescriptor = LlmProviderDescriptor(
  id: llamaCppProviderId,
  label: 'llama.cpp',
  modelPrefix: llamaCppModelPrefix,
  defaultBaseUrl: llamaCppDefaultBaseUrl,
  supportsBaseUrl: true,
);

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
