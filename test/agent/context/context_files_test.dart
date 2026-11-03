import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/context/context_builder.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/session_state.dart';
import 'package:probably_works/agent/workspace/workspace_context_loader.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/openrouter/openrouter_llm_provider.dart';

void main() {
  final now = DateTime(2026, 11, 3);
  final chat = Chat(
    id: 'c1',
    hostId: 'local',
    title: 't',
    createdAt: now,
    updatedAt: now,
    policyMode: PolicyMode.yolo,
    model: 'vision/model',
  );
  final host = Host(
    id: 'local',
    name: 'Local',
    kind: HostKind.local,
    createdAt: now,
    updatedAt: now,
  );
  final pdfBytes = Uint8List.fromList(utf8.encode('%PDF-1.4'));

  ChatMessage userMessage(List<AttachmentRef> attachments) => ChatMessage(
    id: 'u1',
    chatId: 'c1',
    seq: 1,
    role: MessageRole.user,
    createdAt: now,
    text: 'посмотри файлы',
    attachments: attachments,
  );

  ContextInput input(
    List<ChatMessage> messages, {
    Map<String, List<LlmFilePart>> files = const {},
  }) => ContextInput(
    chat: chat,
    host: host,
    messages: messages,
    state: SessionStateRevision(id: 'r1', chatId: 'c1', createdAt: now),
    workspace: WorkspaceSnapshot.empty,
    recentWindow: 40,
    inlineFiles: files,
  );

  final attached = [
    const AttachmentRef(
      name: 'notes.txt',
      mode: AttachmentMode.attach,
      content: 'текст',
      sizeBytes: 5,
    ),
    const AttachmentRef(
      name: 'scan.pdf',
      mode: AttachmentMode.file,
      mimeType: 'application/pdf',
      sizeBytes: 8,
    ),
  ];

  test('binary file goes as a part only in the request that carries it', () {
    final files = {
      'u1': [
        LlmFilePart(
          name: 'scan.pdf',
          mimeType: 'application/pdf',
          bytes: pdfBytes,
        ),
      ],
    };
    final messages = ContextBuilder().build(
      input([userMessage(attached)], files: files),
    );
    final user = messages.last;

    expect(user.files.single.name, 'scan.pdf');
    expect(user.content, contains('--- attachment: notes.txt ---'));
    expect(
      user.content,
      contains(
        '[attachment: scan.pdf, application/pdf, 8 bytes; content is attached to this message]',
      ),
    );
  });

  test('later requests keep only a marker for the binary file', () {
    final messages = ContextBuilder().build(input([userMessage(attached)]));
    final user = messages.last;

    expect(user.files, isEmpty);
    expect(user.content, contains('--- attachment: notes.txt ---'));
    expect(
      user.content,
      contains(
        'scan.pdf, application/pdf, 8 bytes; content was sent when it was attached',
      ),
    );
    expect(user.content, isNot(contains('[attached path')));
  });

  test('token estimate counts file bytes', () {
    final withFile = ContextBuilder().build(
      input(
        [userMessage(attached)],
        files: {
          'u1': [
            LlmFilePart(
              name: 'scan.pdf',
              mimeType: 'application/pdf',
              bytes: Uint8List(4000),
            ),
          ],
        },
      ),
    );
    final without = ContextBuilder().build(input([userMessage(attached)]));
    expect(
      ContextBuilder.estimateTokens(withFile),
      greaterThan(ContextBuilder.estimateTokens(without) + 900),
    );
  });

  test(
    'openrouter user message with files is a content list with data urls',
    () {
      final message = LlmMessage(
        role: LlmRole.user,
        content: 'что здесь?',
        files: [
          LlmFilePart(
            name: 'pic.png',
            mimeType: 'image/png',
            bytes: Uint8List.fromList([1, 2]),
          ),
          LlmFilePart(
            name: 'scan.pdf',
            mimeType: 'application/pdf',
            bytes: pdfBytes,
          ),
        ],
      );
      final json =
          openRouterMessageOf(message).toJson()! as Map<String, dynamic>;
      final content = (json['content'] as List).cast<Map<String, dynamic>>();

      expect(content.map((p) => p['type']), ['text', 'image_url', 'file']);
      expect(content.first['text'], 'что здесь?');
      expect(
        (content[1]['image_url'] as Map)['url'],
        startsWith('data:image/png;base64,'),
      );
      final file = content[2]['file'] as Map;
      expect(file['filename'], 'scan.pdf');
      expect(file['file_data'], startsWith('data:application/pdf;base64,'));
    },
  );

  test('plain user message stays a string', () {
    final json =
        openRouterMessageOf(const LlmMessage.user('привет')).toJson()!
            as Map<String, dynamic>;
    expect(json['content'], 'привет');
  });
}
