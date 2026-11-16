import 'package:pw_agent/agent/context/context_builder.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/session_state.dart';
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
}
