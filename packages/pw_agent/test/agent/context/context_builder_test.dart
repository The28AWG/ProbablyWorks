import 'package:pw_agent/agent/context/context_builder.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/session_state.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/agent/workspace/workspace_context_loader.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:test/test.dart';

Host _host() => Host(
  id: 'h',
  name: 'host',
  kind: HostKind.local,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Chat _chat() => Chat(
  id: 'c',
  hostId: 'h',
  title: 'chat',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

ChatMessage _message(AttachmentRef attachment) => ChatMessage(
  id: 'm1',
  chatId: 'c',
  seq: 1,
  role: MessageRole.user,
  createdAt: DateTime(2026),
  text: 'look at this',
  attachments: [attachment],
);

AttachmentRef _text(String content) => AttachmentRef(
  name: 'notes.txt',
  mode: AttachmentMode.attach,
  content: content,
  sizeBytes: content.length,
);

/// Текст user-сообщения, который увидит модель.
String _userContent(
  ContextBuilder builder,
  AttachmentRef attachment, {
  AppLimits limits = AppLimits.defaults,
  int? contextLimit,
}) {
  final llm = builder.build(
    ContextInput(
      chat: _chat(),
      host: _host(),
      messages: [_message(attachment)],
      state: SessionStateRevision(
        id: 'r',
        chatId: 'c',
        createdAt: DateTime(2026),
      ),
      workspace: const WorkspaceSnapshot(),
      recentWindow: 40,
      limits: limits,
      contextLimit: contextLimit,
    ),
  );
  return llm.firstWhere((m) => m.role == LlmRole.user).content;
}

/// Сколько символов вложения попало в контекст по строке-указателю.
int _shownChars(String content) {
  final match = RegExp(r'preview (\d+) of (\d+) chars').firstMatch(content);
  expect(match, isNotNull, reason: 'указатель превью должен быть в контексте');
  return int.parse(match!.group(1)!);
}

void main() {
  final builder = ContextBuilder();

  test('a small attachment is sent whole and has no pointer', () {
    final content = _userContent(builder, _text('hello world'));

    expect(content, contains('hello world'));
    expect(content, isNot(contains('read_run_output')));
  });

  test('a large attachment is previewed up to the configured limit', () {
    final content = _userContent(builder, _text('x' * 20000));

    expect(content, contains('preview 4000 of 20000 chars'));
    expect(content, contains('read_run_output attachment="notes.txt"'));
    expect(content, contains('message_id=m1'));
  });

  test('the rest of a previewed attachment is not in the context', () {
    final body = '${'a' * 20000}TAIL-MARKER';
    final content = _userContent(builder, _text(body));

    expect(content, isNot(contains('TAIL-MARKER')));
  });

  test('a full window shrinks the preview to metadata only', () {
    final content = _userContent(
      builder,
      _text('x' * 20000),
      limits: AppLimits.defaults.copyWith(contextReserveTokens: 0),
      contextLimit: 1,
    );

    expect(_shownChars(content), 0);
    expect(content, contains('read_run_output attachment="notes.txt"'));
  });

  test('an unknown window keeps the configured preview limit', () {
    final content = _userContent(builder, _text('x' * 20000));

    expect(_shownChars(content), AppLimits.defaults.attachmentInlineChars);
  });

  test('a binary attachment is a note, not text', () {
    final content = _userContent(
      builder,
      const AttachmentRef(
        name: 'photo.png',
        mode: AttachmentMode.file,
        mimeType: 'image/png',
        sizeBytes: 1024,
      ),
    );

    expect(content, contains('[attachment: photo.png, image/png, 1024 bytes'));
    expect(content, isNot(contains('read_run_output')));
  });

  group('stable prefix', () {
    ChatMessage stamped(String id, int seq, MessageRole role, DateTime at) =>
        ChatMessage(
          id: id,
          chatId: 'c',
          seq: seq,
          role: role,
          createdAt: at,
          text: 'step $seq',
        );

    List<LlmMessage> buildWith(List<ChatMessage> messages) => builder.build(
      ContextInput(
        chat: _chat(),
        host: _host(),
        messages: messages,
        state: SessionStateRevision(
          id: 'r',
          chatId: 'c',
          createdAt: DateTime(2026),
        ),
        workspace: const WorkspaceSnapshot(),
        recentWindow: 40,
      ),
    );

    test('the send time is in the user message and never changes', () {
      final user = stamped('u', 1, MessageRole.user, DateTime(2026, 1, 1, 10));
      final assistant = stamped(
        'a',
        2,
        MessageRole.assistant,
        DateTime(2026, 1, 1, 10, 1),
      );
      final first = buildWith([user]);
      final second = buildWith([user, assistant]);

      // Время отправки пишется в сообщение, поэтому на следующем шаге оно то
      // же самое, а префикс запроса совпадает побайтно.
      final userFirst = first.firstWhere((m) => m.role == LlmRole.user);
      final userSecond = second.firstWhere((m) => m.role == LlmRole.user);
      expect(userFirst.content, contains('[sent at: 2026-01-01T10:00:00.000'));
      expect(userSecond.content, userFirst.content);
    });

    test('no current-time line is added after the history', () {
      final messages = buildWith([
        stamped('u', 1, MessageRole.user, DateTime(2026, 1, 1, 10)),
      ]);

      expect(
        messages.any((m) => m.content.contains('[current time:')),
        isFalse,
      );
    });
  });

  group('old tool output', () {
    ChatMessage message(
      int seq,
      MessageRole role, {
      String text = '',
      List<ToolCallRef> calls = const [],
      String? toolCallId,
    }) => ChatMessage(
      id: 'm$seq',
      chatId: 'c',
      seq: seq,
      role: role,
      createdAt: DateTime(2026),
      text: text,
      toolCalls: calls,
      toolCallId: toolCallId,
    );

    List<ChatMessage> history({String name = ToolNames.readFile}) => [
      message(1, MessageRole.user, text: 'do it'),
      message(
        2,
        MessageRole.assistant,
        calls: [ToolCallRef(id: 'c1', name: name, arguments: '{}')],
      ),
      message(3, MessageRole.tool, text: 'x' * 5000, toolCallId: 'c1'),
      message(4, MessageRole.assistant, text: 'done'),
      message(
        5,
        MessageRole.assistant,
        calls: [ToolCallRef(id: 'c2', name: name, arguments: '{}')],
      ),
      message(6, MessageRole.tool, text: 'y' * 5000, toolCallId: 'c2'),
      // Новый ход пользователя: результаты выше уже не текущий ход.
      message(7, MessageRole.user, text: 'next'),
    ];

    List<LlmMessage> build(List<ChatMessage> messages, {int keepSteps = 1}) =>
        builder.build(
          ContextInput(
            chat: _chat(),
            host: _host(),
            messages: messages,
            state: SessionStateRevision(
              id: 'r',
              chatId: 'c',
              createdAt: DateTime(2026),
            ),
            workspace: const WorkspaceSnapshot(),
            recentWindow: 40,
            limits: AppLimits.defaults.copyWith(toolOutputKeepSteps: keepSteps),
          ),
        );

    String toolContent(List<LlmMessage> llm, String callId) => llm
        .firstWhere((m) => m.role == LlmRole.tool && m.toolCallId == callId)
        .content;

    test('an old result is elided, a recent one is kept', () {
      final llm = build(history());

      expect(toolContent(llm, 'c1'), contains('[elided: 5000 chars'));
      expect(toolContent(llm, 'c1'), isNot(contains('x' * 5000)));
      expect(toolContent(llm, 'c2'), contains('y' * 5000));
      expect(toolContent(llm, 'c2'), isNot(contains('[elided')));
    });

    test('the elision is deterministic across builds', () {
      final first = build(history());
      final second = build(history());

      expect(toolContent(first, 'c1'), toolContent(second, 'c1'));
    });

    test('a state-confirming result is never elided', () {
      final llm = build(history(name: ToolNames.writeFile));

      expect(toolContent(llm, 'c1'), contains('x' * 5000));
      expect(toolContent(llm, 'c1'), isNot(contains('[elided')));
    });

    test('the current user turn is never elided', () {
      final llm = build([
        message(1, MessageRole.user, text: 'do it'),
        message(
          2,
          MessageRole.assistant,
          calls: [
            ToolCallRef(id: 'c1', name: ToolNames.readFile, arguments: '{}'),
          ],
        ),
        message(3, MessageRole.tool, text: 'x' * 5000, toolCallId: 'c1'),
        message(
          4,
          MessageRole.assistant,
          calls: [
            ToolCallRef(id: 'c2', name: ToolNames.readFile, arguments: '{}'),
          ],
        ),
        message(5, MessageRole.tool, text: 'y' * 5000, toolCallId: 'c2'),
        message(
          6,
          MessageRole.assistant,
          calls: [
            ToolCallRef(id: 'c3', name: ToolNames.readFile, arguments: '{}'),
          ],
        ),
        message(7, MessageRole.tool, text: 'z' * 5000, toolCallId: 'c3'),
      ]);

      for (final id in ['c1', 'c2', 'c3']) {
        expect(toolContent(llm, id), isNot(contains('[elided')));
      }
    });

    test('zero keep steps disables elision', () {
      final llm = build(history(), keepSteps: 0);

      expect(toolContent(llm, 'c1'), contains('x' * 5000));
      expect(toolContent(llm, 'c1'), isNot(contains('[elided')));
    });

    test('a short old result is not marked as elided', () {
      final llm = build([
        message(1, MessageRole.user, text: 'do it'),
        message(
          2,
          MessageRole.assistant,
          calls: [
            ToolCallRef(id: 'c1', name: ToolNames.readFile, arguments: '{}'),
          ],
        ),
        message(3, MessageRole.tool, text: 'ok', toolCallId: 'c1'),
        message(4, MessageRole.assistant, text: 'done'),
        message(5, MessageRole.user, text: 'next'),
      ]);

      // Результат короче превью: заголовок «elided» только добавлял бы шум.
      expect(toolContent(llm, 'c1'), contains('ok'));
      expect(toolContent(llm, 'c1'), isNot(contains('[elided')));
    });
  });
}
