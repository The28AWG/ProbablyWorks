import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:probably_works/test_support/pipe_pty_launcher.dart';
import 'package:pw_agent/agent/api/chat_run_stopper.dart';
import 'package:pw_agent/agent/api/local_data_api.dart';
import 'package:pw_agent/agent/cleanup/chat_deletion_service.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/agent/project/project_lifecycle.dart';
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';
import 'package:pw_agent/agent/turn/turn_changeset_service.dart';
import 'package:pw_agent/agent/turn/turn_changeset_store.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/mcp_server_repository.dart';
import 'package:pw_agent/core/data/policy_profile_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/data/saved_model_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/data/virtual_host_provisioner.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/host/host_runtime_factory.dart';
import 'package:pw_agent/host/ssh_connection_pool.dart';
import 'package:pw_agent/providers/ai/llm_provider_registry.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/model_runtime_service.dart';
import 'package:pw_agent/providers/ai/provider_settings_store.dart';

final _now = DateTime.utc(2026, 11, 21);

class _NoopStopper implements ChatRunStopper {
  @override
  Future<void> stopChat(String chatId) => Future<void>.value();
}

final class _CreatingDeletion implements ChatDeletionService {
  _CreatingDeletion(this._inner, this._onCreate);

  final ChatDeletionService _inner;
  final Future<void> Function() _onCreate;

  @override
  Future<void> delete(String chatId) => _inner.delete(chatId);

  @override
  Future<void> deleteTree(List<Chat> tree) async {
    await _onCreate();
    await _inner.deleteTree(tree);
  }
}

void main() {
  late AppDatabase db;
  late Directory temp;
  late AppPaths paths;
  late SettingsRepository settings;
  late MemorySecretStore secrets;
  late HostRepository hosts;
  late ChatRepository chats;
  late ProjectRepository projects;
  late ProjectLifecycleService lifecycle;
  late ExecLogStore logs;
  late TurnChangesetService turnChangesets;
  late ChatDeletionService deletion;
  late LlmProviderRegistry registry;
  late ModelCatalogService catalog;
  late ModelRuntimeService runtime;
  late LocalDataApi api;

  LocalDataApi apiWith(ChatDeletionService deletion) => LocalDataApi(
    db,
    paths,
    settings,
    chats,
    deletion,
    catalog,
    runtime,
    registry,
  );

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('pw_data');
    paths = AppPaths.forSupport(temp);
    db = openAppDatabase(paths.support);
    secrets = MemorySecretStore();
    settings = SettingsRepository(db);
    await settings.preload();
    chats = ChatRepository(db);
    projects = ProjectRepository(db);
    hosts = HostRepository(db, secrets);
    await hosts.save(
      Host(
        id: HostRepository.localHostId,
        name: 'Local',
        kind: HostKind.local,
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    final runtimes = HostRuntimeFactory(
      SshConnectionPool(hosts, secrets, settings, HostKeyConfirmations()),
      const PipePtyLauncher(),
      VirtualHostProvisioner(db),
    );
    lifecycle = ProjectLifecycleService(db, projects, hosts, runtimes);
    logs = ExecLogStore(paths.root);
    turnChangesets = TurnChangesetService(TurnChangesetStore(paths.root));
    registry = LlmProviderRegistry([]);
    catalog = ModelCatalogService(SavedModelRepository(db), registry);
    runtime = ModelRuntimeService(registry);
    deletion = ChatDeletionService(
      chats,
      settings,
      InteractionBroker(),
      logs,
      turnChangesets,
      lifecycle,
      _NoopStopper(),
    );
    api = apiWith(deletion);
  });

  tearDown(() async {
    await db.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<Project> project(String id) async {
    final value = Project(
      id: id,
      hostId: HostRepository.localHostId,
      name: id,
      workspace: '/work/$id',
      workspaceKey: '/work/$id',
      createdAt: _now,
      updatedAt: _now,
    );
    await projects.save(value);
    return value;
  }

  Future<void> chat(
    String id, {
    required String projectId,
    ChatKind kind = ChatKind.main,
    String? parentChatId,
    DateTime? updatedAt,
  }) => chats.saveChat(
    Chat(
      id: id,
      hostId: HostRepository.localHostId,
      projectId: projectId,
      title: id,
      kind: kind,
      parentChatId: parentChatId,
      rootChatId: parentChatId,
      depth: parentChatId == null ? 0 : 1,
      createdAt: _now,
      updatedAt: updatedAt ?? _now,
    ),
  );

  Future<void> message(String id, String chatId, {int seq = 1, String? text}) =>
      chats.insertMessage(
        ChatMessage(
          id: id,
          chatId: chatId,
          seq: seq,
          role: MessageRole.user,
          text: text ?? 'hello $id',
          createdAt: _now,
        ),
      );

  void file(String path, [String text = 'log']) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  test('usage counts chats, messages and chat files', () async {
    final value = await project('p1');
    await chat('c1', projectId: value.id);
    await chat(
      'sub',
      projectId: value.id,
      kind: ChatKind.subagent,
      parentChatId: 'c1',
    );
    await message('m1', 'c1');
    final tasks = ScheduledTaskRepository(db);
    await tasks.create(chatId: 'c1', prompt: 'later', dueAt: _now);
    final dispatched = await tasks.create(
      chatId: 'c1',
      prompt: 'done',
      dueAt: _now,
    );
    await tasks.markDispatched(dispatched.id);
    final failed = await tasks.create(
      chatId: 'c1',
      prompt: 'failed',
      dueAt: _now,
    );
    await tasks.markFailed(failed.id, 'offline');
    final cancelled = await tasks.create(
      chatId: 'c1',
      prompt: 'cancelled',
      dueAt: _now,
    );
    await tasks.cancel(cancelled.id);
    file(p.join(paths.root.path, 'chats', 'c1', 'runs', 'run.log'), 'output');

    final usage = await api.usage();

    expect(usage.chats, 1);
    expect(usage.subagentChats, 1);
    expect(usage.messages, 1);
    expect(usage.scheduledTasks, 1);
    expect(usage.completedTasks, 1);
    expect(usage.failedTasks, 1);
    expect(usage.cancelledTasks, 1);
    expect(usage.chatFilesBytes, greaterThan(0));
  });

  test('clearing all removes chats, files and per-chat settings', () async {
    final value = await project('p1');
    await chat('c1', projectId: value.id);
    await chat(
      'sub',
      projectId: value.id,
      kind: ChatKind.subagent,
      parentChatId: 'c1',
    );
    await message('m1', 'c1');
    await settings.saveDailyBudget('c1', 1.5);
    await settings.write(SettingsRepository.keyDefaultModel, 'keep/model');
    file(p.join(paths.root.path, 'chats', 'c1', 'runs', 'run.log'));
    file(p.join(paths.root.path, 'chats', 'sub', 'runs', 'run.log'));
    file(p.join(paths.root.path, 'chats', 'sub', 'turns', 't1', 'm.json'));

    final result = await api.clearHistory(olderThanDays: null);

    expect(result.deletedChats, 2);
    expect(result.freedBytes, greaterThan(0));
    expect(await chats.allChats(), isEmpty);
    expect(await chats.searchMessagesAll('hello'), isEmpty);
    expect(
      await settings.read(SettingsRepository.dailyBudgetKey('c1')),
      isNull,
    );
    expect(
      await settings.read(SettingsRepository.keyDefaultModel),
      'keep/model',
    );
    expect(await hosts.byId(HostRepository.localHostId), isNotNull);
    expect(
      Directory(p.join(paths.root.path, 'chats', 'c1')).existsSync(),
      isFalse,
    );
    expect(
      Directory(p.join(paths.root.path, 'chats', 'sub')).existsSync(),
      isFalse,
    );
    // Проект без чатов уходит в архив, но память и настройки не удаляются.
    expect((await projects.byId(value.id))?.isArchived, isTrue);
  });

  test(
    'age-based cleanup keeps recent chats and removes old subtrees',
    () async {
      final value = await project('p1');
      final old = _now.subtract(const Duration(days: 40));
      await chat('old', projectId: value.id, updatedAt: old);
      await chat(
        'old-sub',
        projectId: value.id,
        kind: ChatKind.subagent,
        parentChatId: 'old',
        updatedAt: _now,
      );
      await chat('recent', projectId: value.id, updatedAt: _now);
      await message('m-old', 'old');
      await message('m-recent', 'recent', seq: 1);
      await settings.saveDailyBudget('old', 1);
      await settings.saveDailyBudget('recent', 2);

      final result = await api.clearHistory(olderThanDays: 30);

      expect(result.deletedChats, 2);
      expect(await chats.chat('old'), isNull);
      expect(await chats.chat('old-sub'), isNull);
      expect(await chats.chat('recent'), isNotNull);
      expect(
        await settings.read(SettingsRepository.dailyBudgetKey('old')),
        isNull,
      );
      expect(
        await settings.read(SettingsRepository.dailyBudgetKey('recent')),
        '2.000000',
      );
    },
  );

  test('reset removes preferences but keeps secrets and user data', () async {
    final value = await project('p1');
    await chat('c1', projectId: value.id);
    await settings.write(SettingsRepository.keyDefaultModel, 'openai/gpt-4o');
    await settings.write(
      providerSettingKey('openrouter', 'baseUrl'),
      'http://example.test',
    );
    await settings.write(SettingsRepository.keyLimits, '{"steps": 10}');
    await settings.write(
      SettingsRepository.trustKey(HostRepository.localHostId, '/work/p1'),
      'yes',
    );
    await settings.saveDailyBudget('c1', 1.5);
    await settings.write(SettingsRepository.keyPermissionsMigrated, 'yes');
    await secrets.write(providerApiKeyName('openrouter'), 'sk-or-v1-secret');
    await McpServerRepository(db).upsert(
      McpServerConfig(
        id: 'mcp-1',
        name: 'server',
        transport: McpTransport.stdio,
        source: McpServerSource.user,
        command: 'server',
        createdAt: _now,
        updatedAt: _now,
      ),
    );
    await PolicyProfileRepository(db).save(
      PolicyProfile(
        id: 'policy-1',
        name: 'custom',
        profile: const SecurityProfile(),
        createdAt: _now,
        updatedAt: _now,
      ),
    );

    await api.resetSettings();

    expect(await settings.read(SettingsRepository.keyDefaultModel), isNull);
    expect(
      await settings.read(providerSettingKey('openrouter', 'baseUrl')),
      isNull,
    );
    expect(await settings.read(SettingsRepository.keyLimits), isNull);
    expect(
      await settings.read(
        SettingsRepository.trustKey(HostRepository.localHostId, '/work/p1'),
      ),
      'yes',
    );
    expect(
      await settings.read(SettingsRepository.dailyBudgetKey('c1')),
      '1.500000',
    );
    expect(
      await settings.read(SettingsRepository.keyPermissionsMigrated),
      'yes',
    );
    expect(
      await secrets.read(providerApiKeyName('openrouter')),
      'sk-or-v1-secret',
    );
    expect(await hosts.byId(HostRepository.localHostId), isNotNull);
    expect(await chats.chat('c1'), isNotNull);
    expect(await McpServerRepository(db).all(), hasLength(1));
    expect(await PolicyProfileRepository(db).all(), hasLength(1));
  });
  test('clearing history compacts the database file', () async {
    final value = await project('p1');
    await chat('c1', projectId: value.id);
    for (var index = 0; index < 120; index++) {
      await message(
        'm$index',
        'c1',
        seq: index + 1,
        text: 'history $index ${'x' * 4096}',
      );
    }
    final before = (await api.usage()).databaseBytes;

    final result = await api.clearHistory();

    final after = (await api.usage()).databaseBytes;
    expect(before, greaterThan(0));
    expect(after, lessThan(before));
    // Снэкбар должен показывать и сжатие базы, а не только файлы чатов.
    expect(result.freedBytes, greaterThanOrEqualTo(before - after));
  });
  test('clearing all removes orphan subagent chats', () async {
    final value = await project('p1');
    await chat(
      'orphan',
      projectId: value.id,
      kind: ChatKind.subagent,
      parentChatId: 'missing',
    );

    final result = await api.clearHistory();

    expect(result.deletedChats, 1);
    expect(await chats.allChats(), isEmpty);
  });
  test('clear all keeps a chat created during deletion', () async {
    final value = await project('p1');
    await chat('c1', projectId: value.id);
    var created = false;
    final raceDeletion = _CreatingDeletion(deletion, () async {
      if (created) return;
      created = true;
      await chats.saveChat(
        Chat(
          id: 'new',
          hostId: HostRepository.localHostId,
          projectId: value.id,
          title: 'new',
          createdAt: _now,
          updatedAt: _now,
        ),
      );
    });
    final raceApi = apiWith(raceDeletion);

    final result = await raceApi.clearHistory();

    expect(result.deletedChats, 1);
    expect(await chats.chat('c1'), isNull);
    expect(await chats.chat('new'), isNotNull);
  });
}
