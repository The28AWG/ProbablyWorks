import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';

void main() {
  late AppDatabase db;
  late ChatRepository chats;
  late ProjectRepository projects;
  late HostRepository hosts;
  final now = DateTime.utc(2026, 11, 12);

  setUp(() async {
    db = openInMemoryDatabase();
    chats = ChatRepository(db);
    projects = ProjectRepository(db);
    hosts = HostRepository(db, MemorySecretStore());
    await hosts.ensureLocalHost(now);
  });

  tearDown(() => db.close());

  Future<Project> project(String id, String key) async {
    final project = Project(
      id: id,
      hostId: 'local',
      name: id,
      workspace: key,
      workspaceKey: key,
      createdAt: now,
      updatedAt: now,
    );
    await projects.save(project);
    return project;
  }

  Future<void> chat(String id, String title, String? projectId) =>
      chats.saveChat(
        Chat(
          id: id,
          hostId: 'local',
          title: title,
          projectId: projectId,
          createdAt: now,
          updatedAt: now,
        ),
      );

  Future<void> message(String id, String chatId, String text, {int seq = 1}) =>
      chats.insertMessage(
        ChatMessage(
          id: id,
          chatId: chatId,
          seq: seq,
          role: MessageRole.user,
          text: text,
          createdAt: now,
        ),
      );

  Future<int> indexedRows() async =>
      (await db.customSelect('SELECT message_id FROM message_search').get())
          .length;

  test('searches messages across projects and within one project', () async {
    final first = await project('p1', '/one');
    final second = await project('p2', '/two');
    await chat('c1', 'First chat', first.id);
    await chat('c2', 'Second chat', second.id);
    await message('m1', 'c1', 'alpha solution in first project');
    await message('m2', 'c2', 'alpha solution in second project');
    await message('m3', 'c2', 'beta only', seq: 2);

    final all = await chats.searchMessagesAll('alpha');

    expect(
      all.map((hit) => hit.chatTitle),
      containsAll(['First chat', 'Second chat']),
    );
    expect(all, hasLength(2));

    final withinFirst = await chats.searchMessagesAll(
      'alpha',
      projectId: first.id,
    );

    expect(withinFirst, hasLength(1));
    expect(withinFirst.single.chatId, 'c1');
    expect(withinFirst.single.message.text, contains('first project'));
  });

  test('deleting a chat removes its index rows', () async {
    await project('p1', '/one');
    await chat('c1', 'First chat', 'p1');
    await message('m1', 'c1', 'alpha');

    await chats.deleteChat('c1');

    expect(await indexedRows(), 0);
    expect(await chats.searchMessagesAll('alpha'), isEmpty);
  });

  test('truncating messages removes their index rows', () async {
    await project('p1', '/one');
    await chat('c1', 'First chat', 'p1');
    await message('m1', 'c1', 'alpha', seq: 1);
    await message('m2', 'c1', 'beta', seq: 2);

    await chats.deleteMessagesFrom('c1', 2);

    expect(await indexedRows(), 1);
    expect(await chats.searchMessagesAll('alpha'), hasLength(1));
    expect(await chats.searchMessagesAll('beta'), isEmpty);
  });

  test('returns no matches for an empty query', () async {
    await project('p1', '/one');
    await chat('c1', 'First chat', 'p1');
    await message('m1', 'c1', 'alpha');

    expect(await chats.searchMessagesAll('   '), isEmpty);
  });
}
