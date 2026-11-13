import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/memory/project_memory_service.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

/// Скриптованный LLM: каждый вызов stream() отдаёт очередной ответ.
class _MemoryLlm implements LlmProvider {
  final script = <List<LlmEvent>>[];
  final requests = <LlmRequest>[];

  @override
  Future<LlmKeyInfo> checkKey() =>
      Future.value(const LlmKeyInfo(label: 'test', usage: 0));

  @override
  Stream<LlmEvent> stream(LlmRequest request) {
    requests.add(request);
    return Stream.fromIterable(script.removeAt(0));
  }

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];
}

LlmToolCall _patch(List<Map<String, Object?>> operations, {String id = 'p'}) =>
    LlmToolCall(
      id: id,
      name: ProjectMemoryService.applyPatchName,
      arguments: jsonEncode({'operations': operations}),
    );

void main() {
  late AppDatabase db;
  late ChatRepository chats;
  late ProjectRepository projects;
  late SettingsRepository settings;
  late _MemoryLlm llm;
  late ProjectMemoryService memory;
  late Project project;
  final now = DateTime.utc(2026, 11, 13);

  setUp(() async {
    db = openInMemoryDatabase();
    chats = ChatRepository(db);
    projects = ProjectRepository(db);
    settings = SettingsRepository(db);
    llm = _MemoryLlm();
    memory = ProjectMemoryService(projects, chats, settings, llm);
    await HostRepository(db, MemorySecretStore()).ensureLocalHost(now);
    await settings.write(SettingsRepository.keyDefaultModel, 'fake/model');
    project = Project(
      id: 'p1',
      hostId: HostRepository.localHostId,
      name: 'app',
      workspace: '/srv/app',
      workspaceKey: '/srv/app',
      createdAt: now,
      updatedAt: now,
    );
    await projects.save(project);
  });

  tearDown(() => db.close());

  test('revise applies append through apply_patch', () async {
    llm.script.add([
      LlmCompleted(
        toolCalls: [
          _patch([
            {'op': 'append', 'text': '## Build\n- pnpm install'},
          ]),
        ],
      ),
    ]);
    llm.script.add([const LlmCompleted()]);

    await memory.revise(project: project, instruction: 'add the build command');

    final saved = await projects.memory(project.id);
    expect(saved?.summary, contains('pnpm install'));
    expect(llm.requests.first.skipReasoning, isFalse);
  });

  test('no tool call leaves memory untouched', () async {
    llm.script.add([const LlmCompleted()]);

    await memory.revise(project: project, instruction: 'nothing durable here');

    expect(await projects.memory(project.id), isNull);
  });

  test('replace requires the old text to occur exactly once', () async {
    await projects.saveMemory(
      ProjectMemory(
        projectId: project.id,
        summary: 'same same',
        updatedAt: now,
      ),
    );
    llm.script.add([
      LlmCompleted(
        toolCalls: [
          _patch([
            {'op': 'replace', 'old': 'same', 'new': 'other'},
          ]),
        ],
      ),
    ]);
    llm.script.add([const LlmCompleted()]);

    await memory.revise(project: project, instruction: 'change it');

    expect((await projects.memory(project.id))?.summary, 'same same');
    final tool = llm.requests.last.messages.last;
    expect(tool.content, contains('more than once'));
  });

  test(
    'too large patch is rejected and compaction is applied next round',
    () async {
      final long = 'x' * ProjectMemory.maxSummaryChars;
      await projects.saveMemory(
        ProjectMemory(projectId: project.id, summary: long, updatedAt: now),
      );
      llm.script.add([
        LlmCompleted(
          toolCalls: [
            _patch([
              {'op': 'append', 'text': 'more'},
            ]),
          ],
        ),
      ]);
      llm.script.add([
        LlmCompleted(
          toolCalls: [
            _patch([
              {'op': 'replace', 'old': long, 'new': '# Project\n- compact'},
            ], id: 'p2'),
          ],
        ),
      ]);
      llm.script.add([const LlmCompleted()]);

      await memory.revise(
        project: project,
        instruction: 'add more and compact',
      );

      expect(
        (await projects.memory(project.id))?.summary,
        '# Project\n- compact',
      );
    },
  );

  test('secret-like text is rejected', () async {
    llm.script.add([
      LlmCompleted(
        toolCalls: [
          _patch([
            {'op': 'append', 'text': 'api_key = sk-or-v1-abcdefghijkl'},
          ]),
        ],
      ),
    ]);
    llm.script.add([const LlmCompleted()]);

    await memory.revise(project: project, instruction: 'save the key');

    expect(await projects.memory(project.id), isNull);
  });

  test('automatic update reads the last turn and saves a patch', () async {
    await chats.saveChat(
      Chat(
        id: 'c1',
        hostId: HostRepository.localHostId,
        title: 'chat',
        projectId: project.id,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await chats.insertMessage(
      ChatMessage(
        id: 'm1',
        chatId: 'c1',
        seq: 1,
        role: MessageRole.user,
        text: 'We always use pnpm in this repo.',
        createdAt: now,
      ),
    );
    await chats.insertMessage(
      ChatMessage(
        id: 'm2',
        chatId: 'c1',
        seq: 2,
        role: MessageRole.assistant,
        text: 'Got it.',
        createdAt: now,
      ),
    );
    llm.script.add([
      LlmCompleted(
        toolCalls: [
          _patch([
            {'op': 'append', 'text': '## Package manager\n- pnpm'},
          ]),
        ],
      ),
    ]);
    llm.script.add([const LlmCompleted()]);

    await memory.updateAfterTurn('c1');

    expect((await projects.memory(project.id))?.summary, contains('pnpm'));
  });

  test('automatic update is rate limited per project', () async {
    await chats.saveChat(
      Chat(
        id: 'c1',
        hostId: HostRepository.localHostId,
        title: 'chat',
        projectId: project.id,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await chats.insertMessage(
      ChatMessage(
        id: 'm1',
        chatId: 'c1',
        seq: 1,
        role: MessageRole.user,
        text: 'Use pnpm.',
        createdAt: now,
      ),
    );
    await chats.insertMessage(
      ChatMessage(
        id: 'm2',
        chatId: 'c1',
        seq: 2,
        role: MessageRole.assistant,
        text: 'Ok.',
        createdAt: now,
      ),
    );
    llm.script.add([const LlmCompleted()]);

    await memory.updateAfterTurn('c1');
    await memory.updateAfterTurn('c1');

    expect(llm.requests, hasLength(1));
  });

  test('optimistic lock rejects a stale write', () async {
    final first = ProjectMemory(
      projectId: project.id,
      summary: 'first',
      updatedAt: now,
    );
    expect(await projects.saveMemory(first), isTrue);
    final saved = await projects.memory(project.id);
    expect(saved?.summary, 'first');
    final locked = saved!;

    expect(
      await projects.saveMemory(
        ProjectMemory(
          projectId: project.id,
          summary: 'second',
          updatedAt: now.add(const Duration(seconds: 1)),
        ),
        expectedUpdatedAt: locked.updatedAt,
      ),
      isTrue,
    );
    expect(
      await projects.saveMemory(
        ProjectMemory(
          projectId: project.id,
          summary: 'stale',
          updatedAt: now.add(const Duration(seconds: 2)),
        ),
        expectedUpdatedAt: locked.updatedAt,
      ),
      isFalse,
    );
    expect((await projects.memory(project.id))?.summary, 'second');
  });
}
