import 'package:flutter/scheduler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Событие агента, о котором нужно сообщить системным уведомлением.
/// Текст строится из типа, а не передаётся готовым: так заголовок и тело переводятся
/// на язык интерфейса в одном месте.
enum AgentNoticeKind {
  /// Ход ждёт решения пользователя по действию (approve/deny).
  approvalNeeded,

  /// Агент задал вопрос и ждёт ответа.
  questionAsked,

  /// Ход завершился штатно.
  turnFinished,

  /// Ход завершился ошибкой.
  turnFailed,

  /// Достигнут лимит шагов: ход приостановлен до действия пользователя.
  stepLimitReached,

  /// Фоновая команда завершилась; её результат передан агенту.
  backgroundFinished,
}

/// Системное уведомление о событии агента. Не показывается, пока окно приложения в фокусе:
/// пользователь и так видит событие в чате.
abstract interface class AppNotifier {
  /// [chatTitle] попадает в заголовок, чтобы по уведомлению было видно, какой чат ждёт.
  /// Пустое название допустимо: тогда в заголовке только действие.
  /// [detail] — дополнительные данные события (сейчас только статус фоновой команды).
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
  });
}

/// Заголовок и текст системного уведомления.
/// Заголовок — «действие · название чата», тело — что нужно сделать пользователю.
({String title, String body}) composeAgentNotice(
  AppLocalizations l10n, {
  required AgentNoticeKind kind,
  required String chatTitle,
  String? detail,
}) {
  final action = switch (kind) {
    AgentNoticeKind.approvalNeeded => l10n.approvalTitle,
    AgentNoticeKind.questionAsked => l10n.questionTitle,
    AgentNoticeKind.turnFinished => l10n.notifyFinishedTitle,
    AgentNoticeKind.turnFailed => l10n.notifyFailedTitle,
    AgentNoticeKind.stepLimitReached => l10n.notifyStepLimitTitle,
    AgentNoticeKind.backgroundFinished => l10n.notifyBackgroundTitle,
  };
  final body = switch (kind) {
    AgentNoticeKind.approvalNeeded => l10n.notifyApprovalBody,
    AgentNoticeKind.questionAsked => l10n.notifyQuestionBody,
    AgentNoticeKind.turnFinished => l10n.notifyFinishedBody,
    AgentNoticeKind.turnFailed => l10n.notifyFailedBody,
    AgentNoticeKind.stepLimitReached => l10n.notifyStepLimitBody,
    AgentNoticeKind.backgroundFinished => l10n.notifyBackgroundBody(
      detail ?? '',
    ),
  };
  final name = chatTitle.trim();
  return (title: name.isEmpty ? action : '$action · $name', body: body);
}

/// Нужно ли показывать системное уведомление при данном состоянии жизненного цикла.
///
/// Во Flutter `resumed` означает, что окно в фокусе (на desktop — хотя бы одно окно приложения
/// получило фокус; на мобильных — приложение на переднем плане). Любое другое состояние
/// (`inactive`, `hidden`, `paused`, `detached`) и отсутствие состояния (`null`, до первого кадра)
/// считаем «не в фокусе»: лучше лишнее уведомление, чем пропущенный запрос подтверждения.
bool shouldShowNotification(AppLifecycleState? state) =>
    state != AppLifecycleState.resumed;

/// Уведомления через flutter_local_notifications: Android, iOS, macOS, Linux, Windows.
/// Разрешение спрашиваем при первом уведомлении (Android 13+, iOS, macOS). Отказ или ошибка
/// уведомления не ломают ход агента: событие просто не показывается.
/// Состояние фокуса проверяем в момент вызова, до инициализации плагина и запроса разрешения:
/// если приложение в фокусе, системный запрос разрешения не должен появляться зря.
/// Язык текста берётся из выбранной в настройках локали (как у фоновых уведомлений).
@LazySingleton(as: AppNotifier)
final class PluginAppNotifier implements AppNotifier {
  /// Конструктор для DI. Плагин создаётся здесь: в GetIt его регистрировать не нужно.
  @factoryMethod
  PluginAppNotifier(LocaleController locale)
    : this.withPlugin(FlutterLocalNotificationsPlugin(), locale);

  /// Подмена плагина (тесты и нестандартная инициализация).
  PluginAppNotifier.withPlugin(this._plugin, this._locale);

  final FlutterLocalNotificationsPlugin _plugin;
  final LocaleController _locale;
  final _log = Logger('AppNotifier');

  Future<bool>? _ready;
  Future<void>? _permission;
  var _nextId = 1;

  static const _channelId = 'agent_events';
  static const _channelName = 'Agent events';

  /// Разрешения и каналы не просим при старте: только когда есть что показать.
  /// Если окно в фокусе, ничего не делаем: ни инициализации, ни показа.
  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
  }) async {
    if (!shouldShowNotification(SchedulerBinding.instance.lifecycleState)) {
      return;
    }
    try {
      final text = composeAgentNotice(
        _strings(),
        kind: kind,
        chatTitle: chatTitle,
        detail: detail,
      );
      final ready = _ready ??= _initialize();
      if (!await ready) return;
      final permission = _permission ??= _requestPermissions();
      await permission;
      await _plugin.show(
        id: _nextId++,
        title: text.title,
        body: text.body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(_channelId, _channelName),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
      );
    } on Object catch (error) {
      _log.fine('notification skipped: $error');
    }
  }

  AppLocalizations _strings() =>
      lookupAppLocalizations(resolveAppLocale(_locale.value?.languageCode));

  Future<bool> _initialize() async {
    final ok = await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        windows: WindowsInitializationSettings(
          appName: 'ProbablyWorks',
          appUserModelId: 'ProbablyWorks.App',
          guid: '6c0e2b6a-7f3e-4c1d-9a8b-2f5e7d1c4b90',
        ),
      ),
    );
    return ok ?? false;
  }

  Future<void> _requestPermissions() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }
}
