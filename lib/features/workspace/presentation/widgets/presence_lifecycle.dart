import 'package:auto_route/auto_route.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';

/// Какой чат пользователь видит прямо сейчас.
///
/// Это не presence сервера, а локальное знание тех же маршрутов: вкладка
/// «Настройки» оставляет стек чатов живым, но лента на экране не видна.
/// По этому признаку лента решает, можно ли отмечать новые сообщения
/// прочитанными. Без области (виджет-тесты, отдельный экран) видимость не
/// ограничивается.
class VisibleChatScope extends InheritedWidget {
  const VisibleChatScope({
    required this.chatId,
    this.onAtEndChanged,
    required super.child,
    super.key,
  });

  /// Открытый чат или null, если пользователь не на вкладке чатов.
  final String? chatId;

  /// Сообщает, находится ли лента у нижней границы.
  ///
  /// Нужно присутствию: открытый чат на разделителе непрочитанного или при
  /// прокрутке вверх ещё не значит, что пользователь увидел новое сообщение.
  /// Уведомление в этот момент уместно.
  final ValueChanged<bool>? onAtEndChanged;

  static VisibleChatScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VisibleChatScope>();

  @override
  bool updateShouldNotify(VisibleChatScope oldWidget) =>
      chatId != oldWidget.chatId;
}

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

  /// Видимость приложения для idle-детекта на сервере.
  ///
  /// `focused` остаётся для старого сервера, но новый различает «окно в
  /// фокусе» и «приложение на экране». Свёрнутая вкладка не должна выглядеть
  /// как пользователь, который смотрит чат.
  ClientVisibility _visibility = ClientVisibility.foreground;

  bool _focused = false;

  /// Находится ли открытая лента у нижней границы. Сбрасывается при смене
  /// чата: новая лента может открыться на непрочитанном.
  bool _chatAtEnd = true;

  /// Присутствие уже отправлялось в этой сборке. Нужно, чтобы первая отправка
  /// прошла даже при `null` (нет открытого чата), а последующие дубли не слали
  /// heartbeat на каждую перестройку.
  bool _presenceSent = false;

  /// Видимый чат для [VisibleChatScope]. Отдельный notifier, чтобы смена
  /// вкладки не перестраивала всю рабочую область через `setState`.
  final _visibleChat = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    _listener = AppLifecycleListener(onStateChange: _onLifecycle);
    // ignore: always-remove-listener, снимается в dispose вместе с _tabs
    _tabs = widget.tabs..addListener(_onTabsChanged);
    _watchChatsStack();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _visibility = lifecycle == null || lifecycle == AppLifecycleState.resumed
        ? ClientVisibility.foreground
        : ClientVisibility.background;
    _focused = _visibility == ClientVisibility.foreground;
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    // Старт приложения тоже взаимодействие: без отметки сервер считал бы
    // только что открытое окно давно забытым.
    _noteInteraction();
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
    widget.sessionApi?.setPresence(
      focused: false,
      visibility: ClientVisibility.background,
      clearActiveChat: true,
    );
    _tabs.removeListener(_onTabsChanged);
    _chatsStack?.removeListener(_onChatsStackChanged);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _listener.dispose();
    _visibleChat.dispose();
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState state) {
    _visibility = state == AppLifecycleState.resumed
        ? ClientVisibility.foreground
        : ClientVisibility.background;
    _focused = _visibility == ClientVisibility.foreground;
    // Возврат в приложение — это взаимодействие: иначе после долгой паузы
    // устройство ещё несколько секунд выглядело бы неактивным.
    if (_focused) _noteInteraction();
    widget.sessionApi?.setPresence(focused: _focused, visibility: _visibility);
  }

  /// Отмечает ввод, нажатие или прокрутку для idle-детекта.
  void _noteInteraction() => widget.sessionApi?.noteInteraction();

  /// Клавиатура не всегда попадает в [Listener]: поле ввода может не быть
  /// потомком рабочей области, а глобальный обработчик видит все нажатия.
  bool _onHardwareKey(KeyEvent event) {
    if (event is KeyDownEvent) _noteInteraction();
    return false;
  }

  /// Сообщает, что лента доехала до конца или ушла выше.
  void _reportAtEnd(bool atEnd) {
    if (_chatAtEnd == atEnd || _visibleChat.value == null) return;
    _chatAtEnd = atEnd;
    widget.sessionApi?.setPresence(activeChatAtEnd: atEnd);
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
    // Другой чат открывается на непрочитанном или у конца — до первого
    // сообщения от ленты считаем, что пользователь видит последние сообщения.
    if (chatId != _lastChatId) _chatAtEnd = true;
    _presenceSent = true;
    _lastChatId = chatId;
    // Лента зависит от видимости: при уходе на другую вкладку она перестаёт
    // отмечать сообщения прочитанными, а при возврате догоняет конец.
    _visibleChat.value = chatId;
    widget.sessionApi?.setPresence(
      focused: includeFocus ? _focused : null,
      visibility: includeFocus ? _visibility : null,
      activeChatId: chatId,
      clearActiveChat: chatId == null,
      activeChatAtEnd: _chatAtEnd,
    );
  }

  @override
  Widget build(BuildContext context) => Listener(
    // Listener не поглощает события: он только замечает ввод, чтобы сервер
    // мог отличить активного пользователя от забытого открытого окна.
    behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => _noteInteraction(),
    onPointerMove: (_) => _noteInteraction(),
    onPointerSignal: (_) => _noteInteraction(),
    child: ValueListenableBuilder<String?>(
      valueListenable: _visibleChat,
      builder: (context, chatId, child) => VisibleChatScope(
        chatId: chatId,
        onAtEndChanged: _reportAtEnd,
        child: child!,
      ),
      child: widget.child,
    ),
  );
}
