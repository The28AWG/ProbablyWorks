import 'dart:async';

import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/workspace/presentation/widgets/client_presence.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/client_session_api.dart';

final _now = DateTime.utc(2026, 11, 24, 12);

ClientSessionView _session(
  String id, {
  String? activeChatId,
  bool current = false,
  bool focused = false,
  String platform = 'linux',
  String clientId = '',
  String? deviceId,
}) => ClientSessionView(
  id: id,
  deviceId: deviceId ?? id,
  clientId: clientId,
  clientApp: 'ProbablyWorks',
  clientVersion: '2.0.0',
  clientBuild: '1',
  clientPlatform: platform,
  activeChatId: activeChatId,
  createdAt: _now,
  lastSeenAt: _now,
  expiresAt: _now.add(const Duration(minutes: 1)),
  focused: focused,
  online: true,
  current: current,
);

void main() {
  testWidgets('presence button opens the list with chats and focus', (
    tester,
  ) async {
    final sessions = [
      _session('s1', current: true),
      _session('s2', activeChatId: 'c1', focused: true, platform: 'android'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ClientPresenceIconButton(
            sessions: sessions,
            chatTitles: const {'c1': 'Alpha'},
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ClientPresenceIconButton));
    await tester.pumpAndSettle();

    expect(find.text('Connected screens'), findsOneWidget);
    expect(find.text('ProbablyWorks · 2.0.0 · linux'), findsOneWidget);
    expect(find.text('ProbablyWorks · 2.0.0 · android'), findsOneWidget);
    expect(find.text('#s1'), findsOneWidget);
    expect(find.text('#s2'), findsOneWidget);
    expect(find.textContaining('Viewing: Alpha'), findsOneWidget);
    expect(find.textContaining('This screen'), findsOneWidget);
    expect(find.byIcon(Icons.smartphone_outlined), findsOneWidget);
  });

  test('groups tabs by stable client id', () {
    final groups = groupClientSessions([
      _session('s1', clientId: 'install-1', deviceId: 'fp-a'),
      _session('s2', clientId: 'install-1', deviceId: 'fp-b'),
      _session('s3', clientId: 'install-2', deviceId: 'fp-c'),
      _session('s4', deviceId: 'legacy-device'),
    ]);

    expect(groups, hasLength(3));
    final first = groups.firstWhere((group) => group.key == 'install-1');
    expect(first.sessions.map((session) => session.id), ['s1', 's2']);
    expect(
      groups.firstWhere((group) => group.key == 'install-2').sessions,
      hasLength(1),
    );
    expect(
      groups.firstWhere((group) => group.key == 'legacy-device').sessions,
      hasLength(1),
    );
  });

  testWidgets('expands tabs of one device', (tester) async {
    final sessions = [
      _session('s1', current: true, clientId: 'install-1'),
      _session('s2', focused: true, clientId: 'install-1'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ClientPresenceIconButton(sessions: sessions)),
      ),
    );

    await tester.tap(find.byType(ClientPresenceIconButton));
    await tester.pumpAndSettle();

    expect(find.text('ProbablyWorks · 2.0.0 · linux'), findsOneWidget);
    expect(find.text('2 screens'), findsOneWidget);
    expect(find.text('#s1'), findsOneWidget);
    expect(find.text('#s2'), findsOneWidget);

    await tester.tap(find.text('ProbablyWorks · 2.0.0 · linux'));
    await tester.pumpAndSettle();
    expect(find.text('#s1'), findsNothing);
    expect(find.text('#s2'), findsNothing);

    await tester.tap(find.text('ProbablyWorks · 2.0.0 · linux'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Focused'), findsOneWidget);
  });

  testWidgets('a device stays open when a second screen appears', (
    tester,
  ) async {
    final changes = StreamController<List<ClientSessionView>>.broadcast();
    addTearDown(changes.close);
    final current = _session('s1', current: true);
    final remote = _session('s2', clientId: 'install-remote');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ClientPresenceIconButton(
            sessions: [current, remote],
            changes: changes.stream,
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ClientPresenceIconButton));
    await tester.pumpAndSettle();
    expect(find.text('1 screen'), findsNWidgets(2));

    changes.add([current, remote, _session('s3', clientId: 'install-remote')]);
    await tester.pumpAndSettle();

    expect(find.text('2 screens'), findsOneWidget);
    expect(find.text('#s2'), findsOneWidget);
    expect(find.text('#s3'), findsOneWidget);
  });

  testWidgets('open dialog follows presence changes', (tester) async {
    final changes = StreamController<List<ClientSessionView>>.broadcast();
    addTearDown(changes.close);
    final current = _session('s1', current: true);
    final viewer = _session('s2', activeChatId: 'c1', focused: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ClientPresenceIconButton(
            sessions: [current],
            changes: changes.stream,
            chatTitles: const {'c1': 'Alpha'},
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ClientPresenceIconButton));
    await tester.pumpAndSettle();
    expect(find.text('#s2'), findsNothing);

    changes.add([current, viewer]);
    await tester.pumpAndSettle();
    expect(find.text('#s2'), findsOneWidget);
    expect(find.textContaining('Viewing: Alpha'), findsOneWidget);

    changes.add([current]);
    await tester.pumpAndSettle();
    expect(find.text('#s1'), findsOneWidget);
    expect(find.textContaining('Viewing: Alpha'), findsNothing);
  });

  test('a chat is visible only in a focused session', () {
    final sessions = [
      _session('background', activeChatId: 'c1'),
      _session('phone', activeChatId: 'c1', focused: true),
    ];

    expect(isChatVisibleInPresence(sessions, 'c1'), isTrue);
    expect(isChatVisibleInPresence(sessions, 'c2'), isFalse);
    expect(
      isChatVisibleInPresence([
        _session('background', activeChatId: 'c1'),
      ], 'c1'),
      isFalse,
    );
  });

  test('presence can ignore the current screen', () {
    final sessions = [
      _session('current', activeChatId: 'c1', focused: true, current: true),
      _session('phone', activeChatId: 'c1', focused: true),
    ];

    expect(
      isChatVisibleInPresence(sessions, 'c1', includeCurrent: false),
      isTrue,
    );
    expect(
      isChatVisibleInPresence([sessions.first], 'c1', includeCurrent: false),
      isFalse,
    );
  });

  testWidgets('presence button is disabled without sessions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: ClientPresenceIconButton(sessions: [])),
      ),
    );

    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.onPressed, isNull);
  });
}
