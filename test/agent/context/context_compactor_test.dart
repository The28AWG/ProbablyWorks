import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/context/context_builder.dart';
import 'package:pw_agent/agent/context/context_compactor.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/session_state.dart';
import 'package:pw_agent/agent/workspace/workspace_context_loader.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Ответы сводки по очереди; запросы сохраняются для проверки.
class _ScriptedLlm extends LlmProviderBase {
  _ScriptedLlm()
    : super(const LlmProviderDescriptor(id: 'test', label: 'Test'));

  final List<String> replies = [];
  final List<LlmUsage> usages = [];
  final List<LlmRequest> requests = [];

  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    requests.add(request);
    final text = replies.isEmpty ? '' : replies.removeAt(0);
    return Stream.fromIterable([
      LlmTextDelta(text),
      LlmCompleted(usage: usages.isEmpty ? null : usages.removeAt(0)),
    ]);
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
    await HostRepository(db, MemorySecretStore()).ensureLocalHost(now);
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

  ContextInput input(
    List<ChatMessage> messages, {
    required int recentWindow,
    int? contextLimit,
    List<LlmToolSpec> tools = const [],
  }) => ContextInput(
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
    contextLimit: contextLimit,
    tools: tools,
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

    expect(identical(result.chat, chat), isTrue);
    expect(result.compacted, isFalse);
    expect(llm.requests, isEmpty);
  });

  test(
    'builder keeps the whole history; the compactor decides what to summarize',
    () {
      final messages = [
        for (var seq = 1; seq <= 100; seq++)
          message(seq, seq.isOdd ? MessageRole.user : MessageRole.assistant),
      ];

      final built = ContextBuilder().build(input(messages, recentWindow: 40));

      // system + все 100 сообщений: молчаливое усечение окном недопустимо.
      expect(built, hasLength(101));
    },
  );

  test('a cut moves to the owning assistant, not inside its tool results', () async {
    llm.replies.add('SAFE');
    final messages = [
      message(1, MessageRole.user),
      ChatMessage(
        id: 'm2',
        chatId: 'c1',
        seq: 2,
        role: MessageRole.assistant,
        createdAt: now,
        toolCalls: const [
          ToolCallRef(id: 'c1', name: 'read_file', arguments: '{}'),
        ],
      ),
      ChatMessage(
        id: 'm3',
        chatId: 'c1',
        seq: 3,
        role: MessageRole.tool,
        createdAt: now,
        text: 'one',
        toolCallId: 'c1',
      ),
      ChatMessage(
        id: 'm4',
        chatId: 'c1',
        seq: 4,
        role: MessageRole.tool,
        createdAt: now,
        text: 'two',
        toolCallId: 'c1',
      ),
    ];

    final result = await compactor.compactIfNeeded(
      input(messages, recentWindow: 2),
      summaryModel: 'fake/model',
      forceReason: CompactionReason.manual,
    );

    expect(result.chat.compactionSummary, startsWith('SAFE'));
    // Оставляем assistant и оба его результата: вызов и ответы не разрываются.
    expect(result.chat.compactedUntilSeq, 1);
    expect(result.reason, CompactionReason.manual);
  });

  test('manual compaction ignores the budget and stores a summary', () async {
    llm.replies.add('SUMMARY');
    final messages = [
      for (var seq = 1; seq <= 12; seq++)
        message(seq, seq.isOdd ? MessageRole.user : MessageRole.assistant),
    ];

    llm.usages.add(const LlmUsage(promptTokens: 123, completionTokens: 7));
    final result = await compactor.compactIfNeeded(
      input(messages, recentWindow: 4),
      summaryModel: 'fake/model',
      forceReason: CompactionReason.manual,
    );

    expect(result.chat.compactionSummary, startsWith('SUMMARY'));
    // Время записи нужно модели, если реплика пользователя уже в сводке.
    expect(result.chat.compactionSummary, contains('[written at: '));
    expect(result.chat.compactedUntilSeq, lessThan(12));
    expect(result.reason, CompactionReason.manual);
    // Расход сводки возвращается наружу: он не должен теряться в учёте.
    expect(result.usage?.promptTokens, 123);
    expect(result.usage?.completionTokens, 7);
    expect(llm.requests, hasLength(1));
    expect((await chats.chat('c1'))!.compactionSummary, startsWith('SUMMARY'));
  });

  test('many tool results below the budget do not compact', () async {
    llm.replies.add('STEPS');
    // Больше сорока результатов инструментов, но токенов мало: сжатие — про
    // окно, а не про количество сообщений. Раньше здесь срабатывал порог роста.
    final messages = [
      for (var seq = 1; seq <= 60; seq++)
        message(seq, seq.isOdd ? MessageRole.user : MessageRole.tool),
    ];

    final result = await compactor.compactIfNeeded(
      input(messages, recentWindow: 50),
      summaryModel: 'fake/model',
    );

    expect(result.compacted, isFalse);
    expect(llm.requests, isEmpty);
  });

  test('tool schemas count toward the compaction budget', () async {
    llm.replies.add('TOOLS');
    // Сообщения сами по себе укладываются в мягкий порог (12 000 * 0.7 =
    // 8 400), а вместе со схемами инструментов — нет.
    final messages = [
      for (var seq = 1; seq <= 20; seq++)
        ChatMessage(
          id: 'm$seq',
          chatId: 'c1',
          seq: seq,
          role: seq.isOdd ? MessageRole.user : MessageRole.assistant,
          createdAt: now,
          text: 'x' * 1000,
        ),
    ];
    final schema = LlmToolSpec(
      name: 'read_file',
      description: 'x' * 20000,
      parameters: const {'type': 'object'},
    );

    final result = await compactor.compactIfNeeded(
      input(messages, recentWindow: 10, contextLimit: 20000, tools: [schema]),
      summaryModel: 'fake/model',
    );

    expect(result.compacted, isTrue);
    expect(result.reason, CompactionReason.soft);
  });

  test(
    'the automatic cutoff keeps a token tail, not just N messages',
    () async {
      llm.replies.add('TAIL');
      final messages = [
        for (var seq = 1; seq <= 80; seq++)
          ChatMessage(
            id: 'm$seq',
            chatId: 'c1',
            seq: seq,
            role: seq.isOdd ? MessageRole.user : MessageRole.assistant,
            createdAt: now,
            text: 'x' * 1000,
          ),
      ];

      final result = await compactor.compactIfNeeded(
        input(messages, recentWindow: 10, contextLimit: 30000),
        summaryModel: 'fake/model',
      );

      expect(result.compacted, isTrue);
      final retained = messages
          .where((message) => message.seq > result.chat.compactedUntilSeq)
          .length;
      // Хвост ограничен половиной свободного бюджета, а не десятью
      // сообщениями: для большого окна это позволяет сохранить больше истории.
      expect(retained, greaterThan(10));
      expect(retained, lessThan(messages.length));
    },
  );

  test('the resolved model window wins over the chat field', () async {
    llm.replies.add('WINDOW');
    final messages = [
      for (var seq = 1; seq <= 36; seq++)
        ChatMessage(
          id: 'm$seq',
          chatId: 'c1',
          seq: seq,
          role: seq.isOdd ? MessageRole.user : MessageRole.assistant,
          createdAt: now,
          text: 'x' * 1000,
        ),
    ];

    // В чате окно не записано, но сессия уже разрешила его из каталога.
    final result = await compactor.compactIfNeeded(
      input(messages, recentWindow: 10, contextLimit: 20000),
      summaryModel: 'fake/model',
    );

    expect(result.compacted, isTrue);
    expect(result.reason, CompactionReason.soft);
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
        forceReason: CompactionReason.manual,
      );

      expect(identical(result.chat, chat), isTrue);
      expect(result.compacted, isFalse);
      expect(llm.requests, isEmpty);
    },
  );

  test('a repeated compaction keeps the previous summary', () async {
    chat = chat.copyWith(
      compactionSummary: 'Goal: keep the build green',
      compactedUntilSeq: 2,
    );
    await chats.saveChat(chat);
    llm.replies.add('SUMMARY');
    final messages = [
      message(3, MessageRole.user),
      message(4, MessageRole.assistant),
      message(5, MessageRole.user),
      message(6, MessageRole.assistant),
    ];

    await compactor.compactIfNeeded(
      input(messages, recentWindow: 2),
      summaryModel: 'fake/model',
      forceReason: CompactionReason.manual,
    );

    final request = llm.requests.single;
    expect(
      request.messages.last.content,
      contains('Goal: keep the build green'),
    );
  });

  test('the summary transcript keeps tool calls and their arguments', () async {
    llm.replies.add('SUMMARY');
    final messages = [
      message(1, MessageRole.user),
      ChatMessage(
        id: 'm2',
        chatId: 'c1',
        seq: 2,
        role: MessageRole.assistant,
        createdAt: now,
        toolCalls: const [
          ToolCallRef(
            id: 'c1',
            name: 'run_command',
            arguments: '{"command":"flutter test"}',
          ),
        ],
      ),
      ChatMessage(
        id: 'm3',
        chatId: 'c1',
        seq: 3,
        role: MessageRole.tool,
        createdAt: now,
        text: 'All tests passed',
        toolCallId: 'c1',
      ),
      message(4, MessageRole.assistant),
    ];

    await compactor.compactIfNeeded(
      input(messages, recentWindow: 2),
      summaryModel: 'fake/model',
      forceReason: CompactionReason.manual,
    );

    final transcript = llm.requests.single.messages.last.content;
    expect(transcript, contains('run_command'));
    expect(transcript, contains('flutter test'));
    expect(transcript, contains('All tests passed'));
  });

  test(
    'the summary transcript redacts secrets and marks it untrusted',
    () async {
      const secret = 'super-secret-value';
      Redactor.registerSecret(secret);
      addTearDown(Redactor.clearRegisteredSecrets);

      llm.replies.add('SUMMARY');
      final messages = [
        ChatMessage(
          id: 'm1',
          chatId: 'c1',
          seq: 1,
          role: MessageRole.user,
          createdAt: now,
          text: 'token is $secret',
        ),
        ChatMessage(
          id: 'm2',
          chatId: 'c1',
          seq: 2,
          role: MessageRole.assistant,
          createdAt: now,
          toolCalls: const [
            ToolCallRef(
              id: 'c1',
              name: 'run_command',
              arguments: '{"command":"echo super-secret-value"}',
            ),
          ],
        ),
        ChatMessage(
          id: 'm3',
          chatId: 'c1',
          seq: 3,
          role: MessageRole.tool,
          createdAt: now,
          text: 'output $secret',
          toolCallId: 'c1',
        ),
        message(4, MessageRole.assistant),
      ];

      await compactor.compactIfNeeded(
        input(messages, recentWindow: 2),
        summaryModel: 'fake/model',
        forceReason: CompactionReason.manual,
      );

      final transcript = llm.requests.single.messages.last.content;
      expect(transcript, isNot(contains(secret)));
      expect(
        transcript,
        contains('<untrusted source="conversation transcript">'),
      );
      expect(transcript, contains('</untrusted>'));
    },
  );

  test(
    'the heuristic fallback keeps tool results when the model fails',
    () async {
      // Пустой ответ модели: _summarize уходит в эвристику.
      final messages = [
        message(1, MessageRole.user),
        ChatMessage(
          id: 'm2',
          chatId: 'c1',
          seq: 2,
          role: MessageRole.assistant,
          createdAt: now,
          toolCalls: const [
            ToolCallRef(
              id: 'c1',
              name: 'run_command',
              arguments: '{"command":"flutter test"}',
            ),
          ],
        ),
        ChatMessage(
          id: 'm3',
          chatId: 'c1',
          seq: 3,
          role: MessageRole.tool,
          createdAt: now,
          text: 'All tests passed',
          toolCallId: 'c1',
        ),
        message(4, MessageRole.assistant),
      ];

      final result = await compactor.compactIfNeeded(
        input(messages, recentWindow: 2),
        summaryModel: 'fake/model',
        forceReason: CompactionReason.manual,
      );

      expect(result.chat.compactionSummary, contains('run_command'));
      expect(result.chat.compactionSummary, contains('All tests passed'));
    },
  );
}
