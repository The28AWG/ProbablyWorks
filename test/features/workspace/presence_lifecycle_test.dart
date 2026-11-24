import 'package:auto_route/auto_route.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:probably_works/features/workspace/presentation/widgets/presence_lifecycle.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';

/// Один вызов `setPresence`: так тест видит, что именно ушло на сервер.
typedef _PresenceCall = ({
  bool? focused,
  String? activeChatId,
  bool clearActiveChat,
});

/// Поддельный API присутствия: запоминает вызовы и ничего не отправляет.
final class _RecordingSessionApi implements ClientSessionApi {
  final calls = <_PresenceCall>[];

  _PresenceCall get last => calls.last;

  @override
  Stream<List<ClientSessionView>> get clientSessions => const Stream.empty();

  @override
  Future<List<ClientSessionView>> refreshClientSessions() async => const [];

  @override
  void setPresence({
    bool? focused,
    String? activeChatId,
    bool clearActiveChat = false,
  }) {
    calls.add((
      focused: focused,
      activeChatId: activeChatId,
      clearActiveChat: clearActiveChat,
    ));
  }
}

/// Маршрут стека: тесту важны только имя и параметры.
final class _Route implements RouteData<dynamic> {
  _Route(this.name, [Map<String, dynamic> params = const {}])
    : params = Parameters(params);

  @override
  final String name;

  @override
  final Parameters params;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('RouteData.${invocation.memberName}');
}

/// Стек вкладки чатов: верхний маршрут меняется так же, как при навигации.
final class _FakeStack implements StackRouter {
  final _changes = ChangeNotifier();
  RouteData _top = _Route('NewChatRoute');

  @override
  RouteData get topRoute => _top;

  /// Открывает чат или стартовый экран и уведомляет подписчиков.
  void open(String name, {String? chatId}) {
    _top = _Route(name, chatId == null ? const {} : {'chatId': chatId});
    notify();
  }

  /// Уведомляет без смены маршрута: проверка защиты от лишних heartbeat.
  void notify() => _changes.notifyListeners();

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('StackRouter.${invocation.memberName}');
}

/// Вкладки рабочей области: тесту нужны активный раздел и стек чатов.
final class _FakeTabs implements TabsRouter {
  _FakeTabs(this.chatsStack);

  final _FakeStack chatsStack;
  final _changes = ChangeNotifier();

  var _activeIndex = 0;

  @override
  int get activeIndex => _activeIndex;

  @override
  StackRouter? stackRouterOfIndex(int index) =>
      index == WorkspaceTab.chats.index ? chatsStack : null;

  /// Переключает раздел так же, как `setActiveIndex` в приложении.
  void select(WorkspaceTab tab) {
    _activeIndex = tab.index;
    _changes.notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) => _changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _changes.removeListener(listener);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('TabsRouter.${invocation.memberName}');
}

void main() {
  test('the chats tab reports the open chat', () {
    final tabs = _FakeTabs(_FakeStack());

    expect(visibleChatIdOf(tabs), isNull);
    tabs.chatsStack.open(ChatRoute.name, chatId: 'c1');
    expect(visibleChatIdOf(tabs), 'c1');
  });

  test('another tab hides the still alive chat stack', () {
    final tabs = _FakeTabs(_FakeStack());
    tabs.chatsStack.open(ChatRoute.name, chatId: 'c1');

    // Настройки оставляют стек чатов живым, но пользователь смотрит не на чат.
    tabs.select(WorkspaceTab.settings);
    expect(visibleChatIdOf(tabs), isNull);

    tabs.select(WorkspaceTab.chats);
    expect(visibleChatIdOf(tabs), 'c1');
  });

  testWidgets('publishes the visible chat and clears presence on dispose', (
    tester,
  ) async {
    final tabs = _FakeTabs(_FakeStack());
    final api = _RecordingSessionApi();

    await tester.pumpWidget(
      PresenceLifecycle(tabs: tabs, sessionApi: api, child: const SizedBox()),
    );
    await tester.pump();

    // Стартовый экран: открытого чата нет.
    expect(api.last.activeChatId, isNull);
    expect(api.last.clearActiveChat, isTrue);

    tabs.chatsStack.open(ChatRoute.name, chatId: 'c1');
    await tester.pump();
    expect(api.last.activeChatId, 'c1');
    expect(api.last.clearActiveChat, isFalse);

    // Повторное уведомление без смены маршрута не шлёт ещё один heartbeat.
    final afterOpen = api.calls.length;
    tabs.chatsStack.notify();
    await tester.pump();
    expect(api.calls, hasLength(afterOpen));

    // Уход на другую вкладку снимает активный чат.
    tabs.select(WorkspaceTab.projects);
    await tester.pump();
    expect(api.last.activeChatId, isNull);
    expect(api.last.clearActiveChat, isTrue);

    // Возврат на вкладку чатов восстанавливает присутствие.
    tabs.select(WorkspaceTab.chats);
    await tester.pump();
    expect(api.last.activeChatId, 'c1');

    // Смена профиля уничтожает экран, но не клиентскую сессию: присутствие
    // нужно снять, иначе сервер считал бы чат открытым до конца сессии.
    await tester.pumpWidget(const SizedBox());
    expect(api.last.activeChatId, isNull);
    expect(api.last.clearActiveChat, isTrue);
    expect(api.last.focused, isFalse);
  });
}
