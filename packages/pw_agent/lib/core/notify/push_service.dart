import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/security/secret_store.dart';

/// Настройки и доставка push-уведомлений через внешний relay.
///
/// Relay получает обычный JSON и сам решает, как доставить его в FCM/APNs
/// или другой транспорт. Без URL и токена сервис не делает сетевых запросов.
@lazySingleton
final class PushService {
  PushService(this._settings, this._secrets) : _client = http.Client();

  /// Конструктор для тестов с подменённым HTTP-клиентом.
  PushService.withClient(this._settings, this._secrets, this._client);

  final SettingsRepository _settings;
  final SecretStore _secrets;
  final http.Client _client;

  static const _settingsKey = 'push.settings';
  static const _tokenKey = 'push.relayToken';
  static const _timeout = Duration(seconds: 10);

  Future<PushSettings> load() async {
    final raw = await _settings.read(_settingsKey);
    var enabled = false;
    var relayUrl = '';
    if (raw != null && raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          enabled = json['enabled'] == true;
          relayUrl = '${json['relayUrl'] ?? ''}';
        }
      } on FormatException {
        // Битые настройки не включают push.
      }
    }
    final token = await _secrets.read(_tokenKey);
    return PushSettings(
      enabled: enabled,
      relayUrl: relayUrl,
      hasToken: token != null && token.isNotEmpty,
    );
  }

  Future<void> save(
    PushSettings settings, {
    String? token,
    bool clearToken = false,
  }) async {
    final relayUrl = settings.relayUrl.trim();
    if (settings.enabled || relayUrl.isNotEmpty) {
      _validateUrl(relayUrl);
    }
    if (clearToken) {
      await _secrets.delete(_tokenKey);
    } else if (token != null && token.trim().isNotEmpty) {
      await _secrets.write(_tokenKey, token.trim());
    }
    final hasToken = !clearToken && await _hasToken();
    if (settings.enabled && !hasToken) {
      throw const AgentApiException(
        400,
        'push_token_required',
        'push relay token is required when notifications are enabled',
      );
    }
    if (settings.enabled && relayUrl.isEmpty) {
      throw const AgentApiException(
        400,
        'push_url_required',
        'push relay URL is required when notifications are enabled',
      );
    }
    await _settings.write(
      _settingsKey,
      jsonEncode({'enabled': settings.enabled, 'relayUrl': relayUrl}),
    );
  }

  /// Проверяет доставку тестового уведомления. Без настроек ничего не делает
  /// и возвращает понятную ошибку.
  Future<void> test() async {
    final settings = await load();
    if (!settings.configured) {
      throw const AgentApiException(
        409,
        'push_not_configured',
        'configure push relay URL and token first',
      );
    }
    await _send(settings, kind: AgentNoticeKind.turnFinished, title: 'Test');
  }

  /// Отправляет уведомление, если push настроен. Ошибки не ломают ход агента.
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
  }) async {
    final settings = await load();
    if (!settings.configured) return;
    try {
      await _send(
        settings,
        kind: kind,
        title: chatTitle,
        detail: detail,
        profileId: profileId,
        chatId: chatId,
        approvalId: approvalId,
      );
    } on Object catch (error) {
      AppLog.root.warning('push delivery failed', error);
    }
  }

  Future<bool> _hasToken() async {
    final token = await _secrets.read(_tokenKey);
    return token != null && token.isNotEmpty;
  }

  Future<void> _send(
    PushSettings settings, {
    required AgentNoticeKind kind,
    required String title,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
  }) async {
    final token = await _secrets.read(_tokenKey);
    if (token == null || token.isEmpty) {
      throw const AgentApiException(
        409,
        'push_not_configured',
        'push relay token is missing',
      );
    }
    final request = http.Request('POST', Uri.parse(settings.relayUrl))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'event': kind.name,
        'title': title,
        'detail': detail,
        'profileId': profileId,
        'chatId': chatId,
        'approvalId': approvalId,
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      });
    final response = await _client.send(request).timeout(_timeout);
    await response.stream.drain<void>();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AgentApiException(
        response.statusCode,
        'push_delivery_failed',
        'push relay returned ${response.statusCode}',
      );
    }
  }

  static void _validateUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const AgentApiException(
        400,
        'bad_push_url',
        'push relay URL must be http or https',
      );
    }
  }
}
