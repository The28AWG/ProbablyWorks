import 'dart:async';

import 'package:app_ui/app_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/local_host_presentation.dart';
import 'package:probably_works/features/chats/presentation/bloc/chat_list_cubit.dart';
import 'package:probably_works/features/inbox/presentation/pages/inbox_page.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/attention_api.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/core/data/chat_draft_store.dart';
import 'package:pw_agent/core/domain/host.dart';

void main() {
  testWidgets('shows the empty state when nothing needs attention', (
    tester,
  ) async {
    final api = _FakeInboxApi(AttentionSnapshot.empty);
    await _pump(tester, api);

    expect(find.text('Your inbox is empty'), findsOneWidget);
    expect(find.text('Approval needed'), findsNothing);
  });

  testWidgets('approves a card from the inbox', (tester) async {
    final host = Host(
      id: 'local',
      name: 'Local',
      kind: HostKind.local,
      createdAt: DateTime.utc(2026, 11, 27),
      updatedAt: DateTime.utc(2026, 11, 27),
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final hostLabel = hostDisplayName(host, l10n);
    final api = _FakeInboxApi(
      AttentionSnapshot(
        revision: 1,
        items: [
          ChatAttention(
            chatId: 'c1',
            hostId: 'local',
            title: 'Fix the build',
            reasons: const {ChatAttentionReason.approval},
            approvals: const [
              ApprovalRequest(
                id: 'a1',
                chatId: 'c1',
                toolName: 'run_command',
                summary: 'flutter test',
                reason: 'Run the test command?',
              ),
            ],
            questions: const [],
            editFileChanges: const [],
            unreadCount: 0,
            lastReadSeq: 0,
            lastMessageSeq: 1,
            running: false,
            updatedAt: DateTime.utc(2026, 11, 27),
          ),
        ],
      ),
      hostList: [host],
    );
    await _pump(tester, api);

    expect(find.text('Approval needed'), findsOneWidget);
    expect(find.text('Fix the build · $hostLabel'), findsOneWidget);
    expect(find.textContaining('Local'), findsNothing);
    expect(find.text('Run the test command?'), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await tester.pump();
    expect(api.actions, [ApprovalAction.allowOnce]);
  });

  testWidgets('keeps a typed answer with its question when the list reorders', (
    tester,
  ) async {
    ChatAttention question(
      String chatId,
      String questionId,
      DateTime updatedAt,
    ) => ChatAttention(
      chatId: chatId,
      hostId: 'local',
      title: 'Chat $chatId',
      reasons: const {ChatAttentionReason.question},
      approvals: const [],
      questions: [
        UserQuestion(
          id: questionId,
          chatId: chatId,
          text: 'Question $questionId',
        ),
      ],
      editFileChanges: const [],
      unreadCount: 0,
      lastReadSeq: 0,
      lastMessageSeq: 0,
      running: false,
      updatedAt: updatedAt,
    );

    final api = _FakeInboxApi(
      AttentionSnapshot(
        revision: 1,
        items: [
          question('c1', 'q1', DateTime.utc(2026, 11, 27, 12)),
          question('c2', 'q2', DateTime.utc(2026, 11, 27, 11)),
        ],
      ),
    );
    await _pump(tester, api);

    expect(find.byType(TextField), findsNWidgets(2));
    await tester.enterText(find.byType(TextField).at(0), 'answer for q1');
    await tester.pump();

    // Вопрос из второго чата стал свежее и поднялся выше. Поле ответа должно
    // переехать вместе со своим вопросом, а не остаться на прежней позиции.
    api.emit(
      AttentionSnapshot(
        revision: 2,
        items: [
          question('c2', 'q2', DateTime.utc(2026, 11, 27, 13)),
          question('c1', 'q1', DateTime.utc(2026, 11, 27, 12)),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).controller?.text,
      isEmpty,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller?.text,
      'answer for q1',
    );
  });
}

Future<void> _pump(WidgetTester tester, _FakeInboxApi api) async {
  final cubit = ChatListCubit(api, ChatDraftStore.unbound());
  addTearDown(() async {
    await cubit.close();
    await api.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider.value(value: cubit, child: const InboxPage()),
    ),
  );
  await tester.pumpAndSettle();
}

final class _FakeInboxApi implements AgentApi, AttentionApi {
  _FakeInboxApi(this._snapshot, {this.hostList = const []});

  AttentionSnapshot _snapshot;
  final List<Host> hostList;
  final _statuses = StreamController<AgentStatus>.broadcast();
  final _attention = StreamController<AttentionSnapshot>.broadcast();
  final actions = <ApprovalAction>[];

  /// Публикует новый снимок так же, как живой сервис.
  void emit(AttentionSnapshot snapshot) {
    _snapshot = snapshot;
    _attention.add(snapshot);
  }

  Future<void> dispose() async {
    await _statuses.close();
    await _attention.close();
  }

  @override
  Future<AttentionSnapshot> attention() async => _snapshot;

  @override
  Stream<AttentionSnapshot> get attentionChanges => _attention.stream;

  @override
  Future<void> dismissAttention(String chatId) => Future<void>.value();

  @override
  Future<void> resolveApproval(
    String id,
    ApprovalAction action, {
    String? reason,
  }) async {
    actions.add(action);
  }

  @override
  Future<void> answerQuestion(String id, String? text) => Future<void>.value();

  @override
  Future<void> resolveEditFileChanges(
    String id,
    EditFileChangesChoice choice,
  ) => Future<void>.value();

  @override
  AgentStatus get status => AgentStatus.online;

  @override
  Stream<AgentStatus> get statusChanges => _statuses.stream;

  @override
  Stream<List<Chat>> watchChats() => const Stream.empty();

  @override
  Stream<List<Host>> watchHosts() => Stream.value(hostList);

  @override
  Stream<AgentEvent> get events => const Stream.empty();

  @override
  Stream<ApprovalRequest> get approvals => const Stream.empty();

  @override
  Stream<UserQuestion> get questions => const Stream.empty();

  @override
  Stream<EditFileChangesRequest> get editChanges => const Stream.empty();

  @override
  Set<String> get runningChatIds => const {};

  @override
  Set<String> get waitingChatIds => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('AgentApi is not used in this test');
}
