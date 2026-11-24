import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';

/// Сообщает серверу, когда окно приложения в фокусе и какой чат реально
/// видит пользователь. Это нужно для presence, списка экранов и чтобы не
/// отправлять push туда, где пользователь уже смотрит чат.
///
/// Открытый чат берётся из маршрута, а не из состояния чата: вкладка
/// «Настройки» оставляет стек чатов живым, но пользователь в этот момент не
/// смотрит на чат. Без такой проверки другие экраны считали бы чат открытым, а
/// push мог бы не прийти.
///
/// [tabs] приходит снаружи, а не берётся из контекста: так виджет можно
/// проверить без настоящего [AutoTabsRouter].
class PresenceLifecycle extends StatefulWidget {
  const PresenceLifecycle({
    required this.tabs,
    required this.sessionApi,
    required this.child,
    super.key,
  });

  /// Вкладки рабочей области, чей активный раздел и стек чатов определяют
  /// присутствие.
  final TabsRouter tabs;

  /// Присутствие профиля. `null` — API без клиентских сессий.
  final ClientSessionApi? sessionApi;

  final Widget child;

  @override
  State<PresenceLifecycle> createState() => _PresenceLifecycleState();
}

class _PresenceLifecycleState extends State<PresenceLifecycle> {
  late final AppLifecycleListener _listener;
  late TabsRouter _tabs;

  /// Стек вкладки чатов. Слушаем его отдельно от корня: замена чата внутри
  /// вкладки может не уведомить корневой роутер, и тогда presence оставался
  /// прежним до перезагрузки.
  StackRouter? _chatsStack;
  String? _lastChatId;
  bool _focused = false;

  /// Присутствие уже отправлялось в этой сборке. Нужно, чтобы первая отправка
  /// прошла даже при `null` (нет открытого чата), а последующие дубли не слали
  /// heartbeat на каждую перестройку.
  bool _presenceSent = false;

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onStateChange: _onLifecycle);
    // ignore: always-remove-listener, снимается в dispose вместе с _tabs
    _tabs = widget.tabs..addListener(_onTabsChanged);
    _watchChatsStack();
    _focused =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _publishPresence(includeFocus: true);
    // Первый кадр достраивает стек вкладки: после него повторяем отправку,
    // чтобы чат из deep link не остался без activeChatId.
    _schedulePublish();
  }

  @override
  void didUpdateWidget(covariant PresenceLifecycle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.tabs, widget.tabs)) {
      _tabs.removeListener(_onTabsChanged);
      // ignore: always-remove-listener, предыдущий снят строкой выше, текущий — в dispose
      _tabs = widget.tabs..addListener(_onTabsChanged);
      _watchChatsStack();
      _presenceSent = false;
      _publishPresence(includeFocus: true);
    }
    if (!identical(oldWidget.sessionApi, widget.sessionApi)) {
      _presenceSent = false;
      _publishPresence(includeFocus: true);
    }
  }

  @override
  void dispose() {
    // Экран уходит (например, пользователь сменил профиль), но клиентская
    // сессия профиля живёт в [ProfileService] и продолжает heartbeat. Без
    // сброса сервер до конца сессии считал бы этот экран активным для чата:
    // список экранов врал бы, а push по этому чату не отправлялся бы.
    widget.sessionApi?.setPresence(focused: false, clearActiveChat: true);
    _tabs.removeListener(_onTabsChanged);
    _chatsStack?.removeListener(_onChatsStackChanged);
    _listener.dispose();
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState state) {
    _focused = state == AppLifecycleState.resumed;
    widget.sessionApi?.setPresence(focused: _focused);
  }

  void _onTabsChanged() {
    _watchChatsStack();
    _publishPresence();
  }

  void _onChatsStackChanged() => _publishPresence();

  /// Подписывается на стек вкладки чатов, когда он появляется.
  ///
  /// Стек создаётся лениво, а замена чата внутри него не всегда уведомляет
  /// корневой роутер. Поэтому слушаем именно тот контроллер, чей `topRoute`
  /// меняется при открытии чата.
  void _watchChatsStack() {
    final stack = _tabs.stackRouterOfIndex(WorkspaceTab.chats.index);
    if (identical(stack, _chatsStack)) return;
    _chatsStack?.removeListener(_onChatsStackChanged);
    // ignore: always-remove-listener, предыдущий снят строкой выше, текущий — в dispose
    _chatsStack = stack?..addListener(_onChatsStackChanged);
  }

  /// Повторяет отправку после кадра: к этому моменту маршрут уже построен.
  void _schedulePublish() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _watchChatsStack();
      _publishPresence();
    });
  }

  /// Отправляет фокус и активный чат. Активный чат — только на вкладке чатов:
  /// настройки и проекты не должны выглядеть как открытый чат.
  void _publishPresence({bool includeFocus = false}) {
    final chatId = visibleChatIdOf(_tabs);
    if (!includeFocus && _presenceSent && chatId == _lastChatId) return;
    _presenceSent = true;
    _lastChatId = chatId;
    widget.sessionApi?.setPresence(
      focused: includeFocus ? _focused : null,
      activeChatId: chatId,
      clearActiveChat: chatId == null,
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
