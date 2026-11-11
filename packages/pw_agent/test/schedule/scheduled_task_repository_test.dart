import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late ScheduledTaskRepository tasks;
  final now = DateTime(2026, 11, 11, 12);

  setUp(() async {
    db = openInMemoryDatabase();
    tasks = ScheduledTaskRepository(db);
    await HostRepository(db, MemorySecretStore()).save(
      Host(
        id: 'local',
        name: 'local',
        kind: HostKind.local,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await ChatRepository(db).saveChat(
      Chat(
        id: 'c1',
        hostId: 'local',
        title: 'chat',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() => db.close());

  test('due returns only pending tasks that are time', () async {
    final past = await tasks.create(
      chatId: 'c1',
      prompt: 'past',
      dueAt: now.subtract(const Duration(minutes: 1)),
      now: now,
    );
    await tasks.create(
      chatId: 'c1',
      prompt: 'future',
      dueAt: now.add(const Duration(hours: 1)),
      now: now,
    );
    final dispatched = await tasks.create(
      chatId: 'c1',
      prompt: 'dispatched',
      dueAt: now.subtract(const Duration(minutes: 2)),
      now: now,
    );
    await tasks.markDispatched(dispatched.id);

    final due = await tasks.due(now);

    expect(due.map((task) => task.prompt), ['past']);
    expect(due.single.id, past.id);
  });

  test('status changes are persisted', () async {
    final task = await tasks.create(
      chatId: 'c1',
      prompt: 'run',
      dueAt: now,
      now: now,
    );

    await tasks.markFailed(task.id, 'boom');
    final all = await tasks.all();

    expect(all.single.status, ScheduledTaskStatus.failed);
    expect(all.single.error, 'boom');
  });

  test('cancel removes a task from the due queue', () async {
    final task = await tasks.create(
      chatId: 'c1',
      prompt: 'run',
      dueAt: now,
      now: now,
    );

    await tasks.cancel(task.id);

    expect(await tasks.due(now), isEmpty);
    expect((await tasks.all()).single.status, ScheduledTaskStatus.cancelled);
  });
}
