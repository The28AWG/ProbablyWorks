import 'package:flutter/scheduler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';

/// Системное уведомление о событии агента (ход завершён, нужно подтверждение, ошибка).
/// Не показывается, пока окно приложения в фокусе: пользователь и так видит событие в чате.
abstract interface class AppNotifier {
  Future<void> notify({required String title, required String body});
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
@LazySingleton(as: AppNotifier)
final class PluginAppNotifier implements AppNotifier {
  /// Конструктор для DI. Плагин создаётся здесь: в GetIt его регистрировать не нужно.
  @factoryMethod
  PluginAppNotifier() : this.withPlugin(FlutterLocalNotificationsPlugin());

  /// Подмена плагина (тесты и нестандартная инициализация).
  PluginAppNotifier.withPlugin(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;
  final _log = Logger('AppNotifier');

  Future<bool>? _ready;
  Future<void>? _permission;
  var _nextId = 1;

  static const _channelId = 'agent_events';
  static const _channelName = 'Agent events';

  /// Разрешения и каналы не просим при старте: только когда есть что показать.
  /// Если окно в фокусе, ничего не делаем: ни инициализации, ни показа.
  @override
  Future<void> notify({required String title, required String body}) async {
    if (!shouldShowNotification(SchedulerBinding.instance.lifecycleState)) {
      return;
    }
    try {
      final ready = _ready ??= _initialize();
      if (!await ready) return;
      final permission = _permission ??= _requestPermissions();
      await permission;
      await _plugin.show(
        id: _nextId++,
        title: title,
        body: body,
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
