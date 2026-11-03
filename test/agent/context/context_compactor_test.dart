import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/context/context_builder.dart';
import 'package:probably_works/agent/context/context_compactor.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/session_state.dart';
import 'package:probably_works/agent/workspace/workspace_context_loader.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Ответы сводки по очереди; запросы сохраняются для проверки.
class _ScriptedLlm implements LlmProvider {
  final List<String> replies = [];
  final List<LlmRequest> requests = [];

  @override
  Future<void> checkKey() => Future<void>.value();

  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    requests.add(request);
    final text = replies.isEmpty ? '' : replies.removeAt(0);
    return Stream.fromIterable([LlmTextDelta(text), const LlmCompleted()]);
  }

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];
}

void main() {
  late AppDatabase db;
  late ChatRepository chats;
  late _ScriptedLlm llm;
  late ContextCompactor compactor;
  late Chat chat;
  final now = DateTime(2026, 11, 1);

  setUp(() async {
    db = openInMemoryDatabase();
    chats = ChatRepository(db);
    llm = _ScriptedLlm();
    compactor = ContextCompactor(chats, llm, ContextBuilder());
    await HostRepository(db).ensureLocalHost(now);
    chat = Chat(
      id: 'c1',
      hostId: HostRepository.localHostId,
      title: 't',
      createdAt: now,
      updatedAt: now,
      policyMode: PolicyMode.yolo,
      model: 'fake/model',
    );
    await chats.saveChat(chat);
  });

  tearDown(() => db.close());

  ChatMessage message(int seq, MessageRole role) => ChatMessage(
    id: 'm$seq',
    chatId: 'c1',
    seq: seq,
    role: role,
    createdAt: now,
    text: 'text $seq',
  );

  ContextInput input(List<ChatMessage> messages, {required int recentWindow}) =>
      ContextInput(
        chat: chat,
        host: Host(
          id: 'local',
          name: 'Local',
          kind: HostKind.local,
          createdAt: now,
          updatedAt: now,
        ),
        messages: messages,
        state: SessionStateRevision(id: 'r1', chatId: 'c1', createdAt: now),
        workspace: WorkspaceSnapshot.empty,
        recentWindow: recentWindow,
      );

  test('below the soft budget nothing is compacted', () async {
    final messages = [
      message(1, MessageRole.user),
      message(2, MessageRole.assistant),
      message(3, MessageRole.user),
    ];

    final result = await compactor.compactIfNeeded(
      input(messages, recentWindow: 40),
      summaryModel: 'fake/model',
    );

    expect(identical(result, chat), isTrue);
    expect(llm.requests, isEmpty);
  });

  test('manual compaction ignores the budget and stores a summary', () async {
    llm.replies.add('SUMMARY');
    final messages = [
      for (var seq = 1; seq <= 12; seq++)
        message(seq, seq.isOdd ? MessageRole.user : MessageRole.assistant),
    ];

    final result = await compactor.compactIfNeeded(
      input(messages, recentWindow: 4),
      summaryModel: 'fake/model',
      force: true,
    );

    expect(result.compactionSummary, 'SUMMARY');
    expect(result.compactedUntilSeq, lessThan(12));
    expect(llm.requests, hasLength(1));
    expect((await chats.chat('c1'))!.compactionSummary, 'SUMMARY');
  });

  test('step growth compacts even under the budget', () async {
    llm.replies.add('STEPS');
    // Окно 50 сообщений, из них 50 результатов инструментов: больше порога роста.
    final messages = [
      message(1, MessageRole.user),
      for (var seq = 2; seq <= 4; seq++) message(seq, MessageRole.tool),
      message(5, MessageRole.user),
      for (var seq = 6; seq <= 60; seq++) message(seq, MessageRole.tool),
    ];

    final result = await compactor.compactIfNeeded(
      input(messages, recentWindow: 50),
      summaryModel: 'fake/model',
    );

    expect(result.compactionSummary, 'STEPS');
    expect(result.compactedUntilSeq, 4);
  });

  test(
    'a cut never lands inside a tool batch: nothing to cut means no change',
    () async {
      final messages = [
        message(1, MessageRole.user),
        for (var seq = 2; seq <= 30; seq++) message(seq, MessageRole.tool),
      ];

      final result = await compactor.compactIfNeeded(
        input(messages, recentWindow: 5),
        summaryModel: 'fake/model',
        force: true,
      );

      expect(identical(result, chat), isTrue);
      expect(llm.requests, isEmpty);
    },
  );
}
