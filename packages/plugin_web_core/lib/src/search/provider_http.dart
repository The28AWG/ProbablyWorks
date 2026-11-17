import 'dart:convert';

import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_web_core/src/web_error.dart';

/// Проверяет ответ провайдера и разбирает JSON.
Map<String, dynamic> decodeProviderJson(PluginHttpResult response) {
  if (response.isError) {
    final code = switch (response.statusCode) {
      401 || 403 => 'provider_auth_failed',
      429 => 'provider_rate_limited',
      _ => 'provider_unavailable',
    };
    final hint = switch (response.statusCode) {
      401 || 403 => 'check the API key in the web plugin settings',
      429 => 'wait and try again, or lower the result count',
      _ => 'the search provider returned HTTP ${response.statusCode}',
    };
    throw WebToolException(code, 'search provider request failed', hint: hint);
  }
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } on FormatException {
    // Ниже вернём общую ошибку формата.
  }
  throw const WebToolException(
    'provider_bad_response',
    'search provider returned invalid JSON',
  );
}

String providerString(Object? value) => value is String ? value.trim() : '';

List<Map<String, dynamic>> providerList(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is Map) Map<String, dynamic>.from(item),
      ]
    : const [];
