import 'dart:async';
import 'dart:convert';

import 'package:flutter/scheduler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/core/notify/notification_action.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';

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
final class PluginAppNotifier implements AppNotifier, NotificationActionSink {
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
  NotificationActionHandler? _actionHandler;
  NotificationActionRequest? _pendingAction;
  var _nextId = 1;

  static const _channelId = 'agent_events';
  static const _channelName = 'Agent events';
  static const _approvalCategory = 'agent_approval';
  static const _actionApprove = 'approve';
  static const _actionDeny = 'deny';
  static const _actionOpen = 'open';

  @override
  set actionHandler(NotificationActionHandler? handler) {
    _actionHandler = handler;
    final pending = _pendingAction;
    if (handler == null || pending == null) return;
    _pendingAction = null;
    unawaited(_dispatch(pending));
  }

  /// Инициализация плагина и регистрация категорий действий. Bootstrap
  /// вызывает её после применения языка, чтобы подписи кнопок были
  /// локализованы. Повторный вызов безопасен.
  Future<void> initialize() async {
    await (_ready ??= _initialize());
  }

  /// Разрешения и каналы не просим при старте: только когда есть что показать.
  /// Если окно в фокусе, ничего не делаем: ни инициализации, ни показа.
  @override
  Future<void> notify({
    required AgentNoticeKind kind,
    required String chatTitle,
    String? detail,
    String? profileId,
    String? chatId,
    String? approvalId,
  }) async {
    if (!shouldShowNotification(SchedulerBinding.instance.lifecycleState)) {
      return;
    }
    try {
      final strings = _strings();
      final text = composeAgentNotice(
        strings,
        kind: kind,
        chatTitle: chatTitle,
        detail: detail,
      );
      final ready = _ready ??= _initialize();
      if (!await ready) return;
      final permission = _permission ??= _requestPermissions();
      await permission;
      final approval = kind == AgentNoticeKind.approvalNeeded;
      await _plugin.show(
        id: _nextId++,
        title: text.title,
        body: text.body,
        payload: _encodePayload(
          profileId: profileId,
          chatId: chatId,
          approvalId: approvalId,
        ),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            actions: approval ? _androidActions(strings) : null,
          ),
          iOS: DarwinNotificationDetails(
            categoryIdentifier: approval ? _approvalCategory : null,
          ),
          macOS: DarwinNotificationDetails(
            categoryIdentifier: approval ? _approvalCategory : null,
          ),
          linux: const LinuxNotificationDetails(),
          windows: const WindowsNotificationDetails(),
        ),
      );
    } on Object catch (error) {
      _log.fine('notification skipped: $error');
    }
  }

  List<AndroidNotificationAction> _androidActions(AppLocalizations l10n) => [
    AndroidNotificationAction(
      _actionApprove,
      l10n.notifyActionApprove,
      showsUserInterface: true,
    ),
    AndroidNotificationAction(
      _actionDeny,
      l10n.notifyActionDeny,
      showsUserInterface: true,
    ),
    AndroidNotificationAction(
      _actionOpen,
      l10n.notifyActionOpen,
      showsUserInterface: true,
    ),
  ];

  /// Категория iOS/macOS с теми же действиями. Кнопка «Открыть» не нужна:
  /// нажатие на само уведомление уже открывает чат, поэтому в категории
  /// остаются только approve/deny.
  DarwinNotificationCategory _darwinCategory(AppLocalizations l10n) =>
      DarwinNotificationCategory(
        _approvalCategory,
        actions: [
          DarwinNotificationAction.plain(
            _actionApprove,
            l10n.notifyActionApprove,
            options: const {DarwinNotificationActionOption.foreground},
          ),
          DarwinNotificationAction.plain(
            _actionDeny,
            l10n.notifyActionDeny,
            options: const {DarwinNotificationActionOption.foreground},
          ),
        ],
      );

  static String? _encodePayload({
    String? profileId,
    String? chatId,
    String? approvalId,
  }) {
    if (profileId == null && chatId == null && approvalId == null) return null;
    final data = <String, String>{};
    if (profileId != null) data['profileId'] = profileId;
    if (chatId != null) data['chatId'] = chatId;
    if (approvalId != null) data['approvalId'] = approvalId;
    return jsonEncode(data);
  }

  static Map<String, Object?> _decodePayload(String? payload) {
    if (payload == null || payload.isEmpty) return const {};
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries)
            if (entry.key is String) entry.key as String: entry.value,
        };
      }
    } on FormatException {
      // Битый payload не должен мешать обработке нажатия.
    }
    return const {};
  }

  Future<void> _onResponse(NotificationResponse response) async {
    final data = _decodePayload(response.payload);
    final rawAction = switch (response.actionId) {
      _actionApprove => NotificationActionKind.approve,
      _actionDeny => NotificationActionKind.deny,
      _ => NotificationActionKind.open,
    };
    final approvalId = data['approvalId'] as String?;
    // Без id карточки подтверждение невозможно: остаётся открыть чат.
    final action =
        rawAction == NotificationActionKind.open || approvalId == null
        ? NotificationActionKind.open
        : rawAction;
    await _dispatch(
      NotificationActionRequest(
        action: action,
        profileId: data['profileId'] as String?,
        chatId: data['chatId'] as String?,
        approvalId: approvalId,
      ),
    );
  }

  Future<void> _dispatch(NotificationActionRequest request) async {
    final handler = _actionHandler;
    if (handler == null) {
      _pendingAction = request;
      return;
    }
    try {
      await handler(request);
    } on Object catch (error) {
      _log.warning('notification action failed: $error');
    }
  }

  AppLocalizations _strings() =>
      lookupAppLocalizations(resolveAppLocale(_locale.value?.languageCode));

  Future<bool> _initialize() async {
    final l10n = _strings();
    final ok = await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: [_darwinCategory(l10n)],
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: [_darwinCategory(l10n)],
        ),
        linux: LinuxInitializationSettings(
          defaultActionName: l10n.notifyActionOpen,
        ),
        windows: const WindowsInitializationSettings(
          appName: 'ProbablyWorks',
          appUserModelId: 'ProbablyWorks.App',
          guid: '6c0e2b6a-7f3e-4c1d-9a8b-2f5e7d1c4b90',
        ),
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );
    final ready = ok ?? false;
    if (ready) await _handleLaunchDetails();
    return ready;
  }

  /// Приложение могли запустить нажатием на действие. Плагин отдаёт это
  /// отдельно от `onDidReceiveNotificationResponse`, поэтому проверяем явно.
  Future<void> _handleLaunchDetails() async {
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && response != null) {
        await _onResponse(response);
      }
    } on Object catch (error) {
      _log.fine('notification launch details skipped: $error');
    }
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
