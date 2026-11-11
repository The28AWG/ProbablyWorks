import 'package:app_ui/app_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/local_host_presentation.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/workspace/presentation/navigation/workspace_navigation.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_sidebar.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/test_support/golden_fonts.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/domain/host.dart';

final _now = DateTime.now();

/// Сколько раз панель попросили свернуться, когда тест не передал свой обработчик.
var _collapseCount = 0;

/// Действия панели, когда тест не передал свой обработчик. Пустых обработчиков не держим: их ловит DCM.
var _newChatCount = 0;
final _openedChats = <String>[];
final _openedTabs = <WorkspaceTab>[];

Chat _chat(
  String id,
  String title, {
  DateTime? updatedAt,
  String hostId = 'local',
}) => Chat(
  id: id,
  hostId: hostId,
  title: title,
  createdAt: updatedAt ?? _now,
  updatedAt: updatedAt ?? _now,
);

class _FakeChats implements ChatRepository {
  _FakeChats(this._chats);

  final List<Chat> _chats;

  @override
  Stream<List<Chat>> watchChats() => Stream.value(_chats);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ChatRepository is not used in this test');
}

class _FakeApi implements AgentApi {
  _FakeApi(this._chats, this._hosts);

  final List<Chat> _chats;
  final List<Host> _hosts;

  @override
  Stream<List<Chat>> watchChats() => Stream.value(_chats);

  @override
  Stream<List<Host>> watchHosts() => Stream.value(_hosts);

  @override
  Stream<AgentEvent> get events => Stream.empty();

  @override
  Stream<ApprovalRequest> get approvals => Stream.empty();

  @override
  Stream<UserQuestion> get questions => Stream.empty();

  @override
  Stream<EditFileChangesRequest> get editChanges => Stream.empty();

  @override
  Set<String> get runningChatIds => const {};

  @override
  Set<String> get waitingChatIds => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('AgentApi is not used in this test');
}

/// Поднимает развёрнутую панель. [onCollapse] передаётся наружу для проверки, [selectedChatId] и [activeTab]
/// задают выделение так же, как это делают маршруты в приложении.
Future<void> _pumpSidebar(
  WidgetTester tester, {
  required List<Chat> chats,
  List<Host> hosts = const [],
  ThemeData? theme,
  VoidCallback? onCollapse,
  String? selectedChatId,
  WorkspaceTab activeTab = WorkspaceTab.chats,
  void Function(WorkspaceTab tab)? onOpenTab,
}) async {
  final cubit = ChatListCubit(
    _FakeApi(chats, hosts),
    ChatDraftStore(_FakeChats(chats)),
  );
  addTearDown(cubit.close);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          width: 280,
          height: 560,
          child: BlocProvider.value(
            value: cubit,
            child: WorkspaceSidebar(
              activeTab: activeTab,
              selectedChatId: selectedChatId,
              onCollapse: onCollapse ?? () => _collapseCount++,
              onOpenChat: _openedChats.add,
              onNewChat: () => _newChatCount++,
              onOpenTab: onOpenTab ?? _openedTabs.add,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('chats are grouped by day with sticky headers', (tester) async {
    await _pumpSidebar(
      tester,
      chats: [
        _chat('a', 'Today chat'),
        _chat(
          'b',
          'Yesterday chat',
          updatedAt: _now.subtract(const Duration(days: 1)),
        ),
        _chat(
          'c',
          'Old chat',
          updatedAt: _now.subtract(const Duration(days: 5)),
        ),
      ],
    );

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Earlier'), findsOneWidget);
    expect(find.text('Today chat'), findsOneWidget);
    expect(find.text('Old chat'), findsOneWidget);
  });

  testWidgets('rows show the host under the title', (tester) async {
    final now = DateTime.now();
    await _pumpSidebar(
      tester,
      hosts: [
        Host(
          id: HostRepository.localHostId,
          name: 'Local',
          kind: HostKind.local,
          createdAt: now,
          updatedAt: now,
        ),
        Host(
          id: 'ssh1',
          name: 'build-box',
          kind: HostKind.ssh,
          createdAt: now,
          updatedAt: now,
        ),
      ],
      chats: [
        _chat('a', 'Remote chat', hostId: 'ssh1'),
        _chat('b', 'Local chat'),
      ],
    );

    expect(find.text('Remote chat'), findsOneWidget);
    expect(find.text('build-box'), findsOneWidget);
    expect(find.text('Local chat'), findsOneWidget);
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(localHostTitle(l10n)), findsOneWidget);
    expect(find.byIcon(localHostIcon()), findsOneWidget);
  });

  testWidgets('sidebar header shows the app name', (tester) async {
    await _pumpSidebar(
      tester,
      chats: const [],
      onCollapse: () => _collapseCount++,
    );

    expect(find.text('ProbablyWorks'), findsOneWidget);
  });

  testWidgets('empty list shows the empty state', (tester) async {
    await _pumpSidebar(tester, chats: const []);

    expect(find.text('No chats yet. Create one to start.'), findsOneWidget);
  });

  testWidgets('collapse button reports the tap', (tester) async {
    var collapsed = 0;
    await _pumpSidebar(
      tester,
      chats: [_chat('a', 'Alpha')],
      onCollapse: () => collapsed++,
    );

    await tester.tap(find.byTooltip('Collapse sidebar'));
    await tester.pump();

    expect(collapsed, 1);
  });

  testWidgets('collapsed rail reports the expand tap', (tester) async {
    var expanded = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: WorkspaceRail(
            activeTab: WorkspaceTab.chats,
            onExpand: () => expanded++,
            onNewChat: () => _newChatCount++,
            onOpenTab: _openedTabs.add,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Open sidebar'));
    await tester.pump();

    expect(expanded, 1);
  });

  testWidgets('sidebar tabs report the tapped section', (tester) async {
    final opened = <WorkspaceTab>[];
    await _pumpSidebar(tester, chats: const [], onOpenTab: opened.add);

    await tester.tap(find.text('Settings'));
    await tester.pump();

    expect(opened, [WorkspaceTab.settings]);
  });

  group('golden', () {
    setUpAll(GoldenFonts.load);

    final now = DateTime.now();
    final goldenChats = [
      _chat('a', 'Refactor the auth flow'),
      _chat('b', 'Fix flaky timeline test', hostId: 'ssh1'),
      _chat(
        'c',
        'Plan the Q4 roadmap',
        updatedAt: now.subtract(const Duration(days: 1)),
      ),
      _chat(
        'd',
        'Release notes draft',
        updatedAt: now.subtract(const Duration(days: 5)),
        hostId: 'ssh1',
      ),
    ];
    final goldenHosts = [
      Host(
        id: 'ssh1',
        name: 'build-box',
        kind: HostKind.ssh,
        createdAt: now,
        updatedAt: now,
      ),
    ];

    for (final brightness in Brightness.values) {
      testWidgets('workspace sidebar ${brightness.name}', (tester) async {
        await tester.binding.setSurfaceSize(const Size(300, 580));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _pumpSidebar(
          tester,
          chats: goldenChats,
          hosts: goldenHosts,
          selectedChatId: 'b',
          theme: brightness == Brightness.light
              ? AppTheme.light
              : AppTheme.dark,
        );
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/workspace_sidebar_${brightness.name}.png'),
        );
      });
    }
  });
}
