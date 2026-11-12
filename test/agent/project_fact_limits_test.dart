import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';

void main() {
  late AppDatabase db;
  late ProjectRepository projects;
  final now = DateTime.utc(2026, 11, 12);

  setUp(() async {
    db = openInMemoryDatabase();
    projects = ProjectRepository(db);
    await HostRepository(db, MemorySecretStore()).ensureLocalHost(now);
    await projects.save(
      Project(
        id: 'p1',
        hostId: 'local',
        name: 'project',
        workspace: '/work',
        workspaceKey: '/work',
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  tearDown(() => db.close());

  test('rejects empty and too long facts', () async {
    await expectLater(
      projects.addFact(
        ProjectFact(id: 'empty', projectId: 'p1', text: '   ', createdAt: now),
      ),
      throwsArgumentError,
    );
    await expectLater(
      projects.addFact(
        ProjectFact(
          id: 'long',
          projectId: 'p1',
          text: 'x' * (ProjectRepository.maxFactChars + 1),
          createdAt: now,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('limits the number of facts per project', () async {
    for (var i = 0; i < ProjectRepository.maxFactsPerProject; i++) {
      await projects.addFact(
        ProjectFact(
          id: 'f$i',
          projectId: 'p1',
          text: 'fact $i',
          createdAt: now,
        ),
      );
    }

    await expectLater(
      projects.addFact(
        ProjectFact(
          id: 'over',
          projectId: 'p1',
          text: 'one more',
          createdAt: now,
        ),
      ),
      throwsStateError,
    );
  });
}
