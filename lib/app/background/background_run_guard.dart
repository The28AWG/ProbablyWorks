import 'dart:async';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:probably_works/agent/loop/agent_event.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Работа агента и фон. Фоновых команд у приложения нет, поэтому:
///
/// - Android: пока есть активный ход, поднимается foreground-сервис с постоянным уведомлением.
///   Без него система усыпит процесс и оборвёт SSH-сессию. Когда ходов нет, сервис гасится.
/// - iOS: фоновой работы нет. При сворачивании активные ходы останавливаются через Stop,
///   чтобы команды не оставались на сервере без контроля. В чат пишется причина.
class BackgroundRunGuard {
  BackgroundRunGuard(this._hub, this._locale, {AppPlatform? platform})
    : _platform = platform ?? AppPlatform.current;

  static const _channel = MethodChannel('probably_works/run_service');

  final AgentHub _hub;
  final LocaleController _locale;
  final AppPlatform _platform;
  final _log = Logger('BackgroundRunGuard');

  StreamSubscription<AgentEvent>? _sub;
  var _serviceOn = false;

  void start() {
    if (!_platform.isAndroid) return;
    _sub = _hub.allEvents.listen((event) {
      if (event is AgentTurnStarted || event is AgentTurnFinished) {
        unawaited(_syncService());
      }
    });
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// Приложение ушло с экрана (iOS: сворачивание). Ход на iOS не переживёт фон, поэтому останавливаем.
  Future<void> onHidden() async {
    if (!_platform.isIOS) return;
    final running = _hub.runningChatIds;
    if (running.isEmpty) return;
    final reason = _strings().runStoppedInBackground;
    for (final chatId in running) {
      await _hub.session(chatId).stop(reason: reason);
    }
  }

  Future<void> _syncService() async {
    final running = _hub.runningChatIds.isNotEmpty;
    if (running == _serviceOn) return;
    try {
      if (running) {
        final l10n = _strings();
        await _channel.invokeMethod<void>('start', {
          'title': l10n.runServiceTitle,
          'text': l10n.runServiceText,
          'channel': l10n.runServiceChannel,
        });
      } else {
        await _channel.invokeMethod<void>('stop');
      }
      _serviceOn = running;
    } on PlatformException catch (error) {
      // Система может не разрешить запуск из фона (Android 12+): ход идёт, просто без сервиса.
      _log.warning('run service ${running ? 'start' : 'stop'} failed: $error');
    } on MissingPluginException {
      // Платформа без сервиса (desktop, тесты): работа идёт без него.
    }
  }

  AppLocalizations _strings() =>
      lookupAppLocalizations(resolveAppLocale(_locale.value?.languageCode));
}
