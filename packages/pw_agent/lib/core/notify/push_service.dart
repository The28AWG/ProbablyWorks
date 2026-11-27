import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/push_api.dart';
import 'package:pw_agent/agent/state/domain_change_bus.dart';
import 'package:pw_agent/agent/state/shared_state.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/core/security/secret_store.dart';

/// Настройки и доставка push-уведомлений через внешний relay.
///
/// Relay получает обычный JSON и сам решает, как доставить его в FCM/APNs
/// или другой транспорт. Без URL и токена сервис не делает сетевых запросов.
///
/// Регистрируется модулем `PushServiceModule`: конструктору нужен
/// HTTP-клиент, который создаётся внутри, и необязательный шинный поток
/// изменений.
final class PushService {
  PushService(this._settings, this._secrets, this._chats, {this._changes})
    : _client = http.Client();

  /// Конструктор для тестов с подменённым HTTP-клиентом.
  PushService.withClient(
    this._settings,
    this._secrets,
    this._client, [
    this._changes,
    this._chats,
  ]);

  final SettingsRepository _settings;
  final SecretStore _secrets;
  final http.Client _client;
  final DomainChangeBus? _changes;

  /// Источник общего числа непрочитанного для payload.
  ///
  /// Необязателен: узкие тесты и сборки без базы отправляют push без бейджа,
  /// как раньше. Решение «сколько непрочитанного» принимает агент, а relay
  /// остаётся тупым транспортом.
  final ChatRepository? _chats;

  static const _settingsKey = 'push.settings';
  static const _tokenKey = 'push.relayToken';
  static const _timeout = Duration(seconds: 10);

  Future<PushSettings> load() async {
    final raw = await _settings.read(_settingsKey);
    var enabled = false;
    var relayUrl = '';
    var revision = 0;
    if (raw != null && raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          enabled = json['enabled'] == true;
          relayUrl = '${json['relayUrl'] ?? ''}';
          revision = json['revision'] is num
              ? (json['revision'] as num).toInt()
              : 0;
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
      revision: revision,
    );
  }

  Future<void> save(
    PushSettings settings, {
    String? token,
    bool clearToken = false,
    int? expectedRevision,
  }) async {
    final relayUrl = settings.relayUrl.trim();
    if (settings.enabled || relayUrl.isNotEmpty) {
      _validateUrl(relayUrl);
    }
    // Проверка ревизии и запись — одна транзакция: параллельное сохранение из
    // другого окна не пройдёт между чтением и записью, иначе оба запроса
    // прочитали бы одну ревизию и второй молча затёр первый.
    await _settings.transaction(() async {
      final current = await load();
      if (expectedRevision != null && expectedRevision != current.revision) {
        throw const AgentApiException(
          409,
          'push_conflict',
          'push settings were changed by another client',
        );
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
        jsonEncode({
          'enabled': settings.enabled,
          'relayUrl': relayUrl,
          'revision': current.revision + 1,
        }),
      );
    });
    _changes?.publish(SharedResource.push);
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
  ///
  /// [noticeId] уходит в relay вместе с остальными полями: по нему устройство
  /// обновляет уже показанное уведомление, а [cancel] убирает его. [groupKey]
  /// объединяет карточки одного чата и типа в одну группу, `collapseKey`
  /// оставляет в группе одну строку на карточку при повторной доставке.
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
    String? questionId,
    String? noticeId,
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
        questionId: questionId,
        noticeId: noticeId,
      );
    } on Object catch (error) {
      AppLog.root.warning('push delivery failed', error);
    }
  }

  /// Убирает уведомление из доставленных, если push настроен.
  ///
  /// Отмена адресуется по [noticeId], а не по тексту или позиции: карточку
  /// могли закрыть на другом устройстве, и relay должен снять ровно ту строку,
  /// которую показал. Ошибка отмены не ломает ход агента: устаревшее
  /// уведомление просто останется до следующего действия.
  Future<void> cancel(String noticeId, {String? profileId}) async {
    final settings = await load();
    if (!settings.configured) return;
    try {
      await _sendCancel(settings, noticeId: noticeId, profileId: profileId);
    } on Object catch (error) {
      AppLog.root.warning('push cancel failed', error);
    }
  }

  Future<bool> _hasToken() async {
    final token = await _secrets.read(_tokenKey);
    return token != null && token.isNotEmpty;
  }

  /// Общее непрочитанное или null, если счётчика нет или он недоступен.
  ///
  /// Ошибка чтения не должна отменять уведомление: пропущенный approve хуже
  /// устаревшего бейджа. Следующая доставка или открытое окно исправят число.
  Future<int?> _unreadTotal() async {
    final chats = _chats;
    if (chats == null) return null;
    try {
      return await chats.unreadTotal();
    } on Object catch (error) {
      AppLog.root.fine('push badge count unavailable: $error');
      return null;
    }
  }

  Future<void> _send(
    PushSettings settings, {
    required AgentNoticeKind kind,
    required String title,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
    String? questionId,
    String? noticeId,
  }) async {
    final token = await _readToken();
    final groupKey = agentNoticeGroupKey(
      kind: kind,
      scope: profileId,
      chatId: chatId,
    );
    final request = _request(settings, token, {
      'event': kind.name,
      // Бейдж на устройстве-получателе должен совпасть с открытыми окнами,
      // поэтому сумму считает агент. null — счётчика нет (узкая сборка или
      // ошибка базы): relay не должен угадывать число.
      'badge': await _unreadTotal(),
      'title': title,
      'detail': detail,
      'profileId': profileId,
      'chatId': chatId,
      'approvalId': approvalId,
      'questionId': questionId,
      // Ключ ответа детерминирован для вопроса: повтор действия из
      // уведомления не создаст второй ответ.
      'answerId': questionId == null ? null : agentNoticeAnswerId(questionId),
      'noticeId': noticeId,
      'groupKey': groupKey,
      // Одна карточка — одна строка группы: повторная доставка того же
      // события обновляет её, а не добавляет вторую.
      'collapseKey': noticeId,
      'ttlSeconds': 3600,
      'priority': _priorityOf(kind),
      'actions': _actionsOf(kind),
      'replyInput': kind == AgentNoticeKind.questionAsked,
      'sentAt': DateTime.now().toUtc().toIso8601String(),
    });
    await _deliver(request);
  }

  /// Отправляет отмену отдельным событием `cancel`.
  ///
  /// Контракт relay намеренно не зависит от устройства: агент говорит «сними
  /// уведомление с ключом noticeId», а relay доставляет отмену туда же, куда
  /// ушло исходное событие. Политика выбора устройства остаётся на агенте.
  Future<void> _sendCancel(
    PushSettings settings, {
    required String noticeId,
    String? profileId,
  }) async {
    final token = await _readToken();
    await _deliver(
      _request(settings, token, {
        'event': 'cancel',
        'noticeId': noticeId,
        'profileId': profileId,
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  Future<String> _readToken() async {
    final token = await _secrets.read(_tokenKey);
    if (token == null || token.isEmpty) {
      throw const AgentApiException(
        409,
        'push_not_configured',
        'push relay token is missing',
      );
    }
    return token;
  }

  http.Request _request(
    PushSettings settings,
    String token,
    Map<String, Object?> body,
  ) => http.Request('POST', Uri.parse(settings.relayUrl))
    ..headers['Authorization'] = 'Bearer $token'
    ..headers['Content-Type'] = 'application/json'
    ..body = jsonEncode(body);

  Future<void> _deliver(http.Request request) async {
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

  /// Важность уведомления для платформенного канала.
  ///
  /// Решения и проблемы прерывают пользователя, обычное завершение хода —
  /// нет. Relay лишь передаёт значение в FCM/APNs, поэтому решение остаётся
  /// на агенте, а не на внешнем сервисе.
  static String _priorityOf(AgentNoticeKind kind) => switch (kind) {
    AgentNoticeKind.approvalNeeded ||
    AgentNoticeKind.questionAsked ||
    AgentNoticeKind.turnFailed ||
    AgentNoticeKind.stepLimitReached ||
    AgentNoticeKind.turnBudgetReached ||
    AgentNoticeKind.progressStalled => 'high',
    AgentNoticeKind.turnFinished ||
    AgentNoticeKind.snoozeDue ||
    AgentNoticeKind.attentionDigest ||
    AgentNoticeKind.backgroundFinished => 'default',
  };

  /// Набор действий, который умеет показать получатель.
  ///
  /// Заголовки кнопок не передаются: их переводит клиент, а relay остаётся
  /// тупым транспортом. `reply` означает ввод текста прямо в уведомлении.
  static List<String> _actionsOf(AgentNoticeKind kind) => switch (kind) {
    AgentNoticeKind.approvalNeeded => const ['approve', 'deny', 'open'],
    AgentNoticeKind.questionAsked => const ['reply', 'open'],
    _ => const ['open'],
  };

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
