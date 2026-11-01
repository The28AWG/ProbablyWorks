import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/workspace/workspace_context_loader.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/local_host_runtime.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late WorkspaceContextLoader loader;
  late Directory workspace;
  final runtime = LocalHostRuntime(os: HostOs.posix);
  final now = DateTime(2026, 11, 1);

  setUp(() async {
    db = openInMemoryDatabase();
    settings = SettingsRepository(db);
    loader = WorkspaceContextLoader(settings);
    await HostRepository(db).ensureLocalHost(now);
    workspace = Directory.systemTemp.createTempSync('pw_ws');
  });

  tearDown(() async {
    await db.close();
    workspace.deleteSync(recursive: true);
  });

  Chat chat() => Chat(
    id: 'c1',
    hostId: HostRepository.localHostId,
    title: 't',
    createdAt: now,
    updatedAt: now,
    policyMode: PolicyMode.ask,
    workspace: workspace.path,
  );

  void writeSkill(String name, String description) {
    final dir = Directory('${workspace.path}/.cursor/skills/$name')
      ..createSync(recursive: true);
    File('${dir.path}/SKILL.md').writeAsStringSync(
      '---\nname: $name\ndescription: $description\n---\nbody',
    );
  }

  test('lowercase agents.md is found, but not loaded before the user trusts the workspace', () async {
    File('${workspace.path}/agents.md').writeAsStringSync('be terse');

    final untrusted = await loader.load(chat(), runtime, HostOs.posix);
    expect(untrusted.needsTrust, isTrue);
    expect(untrusted.agentsMd, isNull);

    await settings.setTrusted(
      HostRepository.localHostId,
      workspace.path,
      trusted: true,
    );
    final trusted = await loader.load(chat(), runtime, HostOs.posix);
    expect(trusted.needsTrust, isFalse);
    expect(trusted.agentsMd, contains('be terse'));
  });

  test('AGENTS.md under .probablyworks is picked up as well', () async {
    Directory('${workspace.path}/.probablyworks').createSync();
    File('${workspace.path}/.probablyworks/AGENTS.md')
        .writeAsStringSync('from dot dir');
    await settings.setTrusted(
      HostRepository.localHostId,
      workspace.path,
      trusted: true,
    );

    final snapshot = await loader.load(chat(), runtime, HostOs.posix);
    expect(snapshot.agentsMd, contains('from dot dir'));
  });

  test('skills from .cursor/skills are scanned into a catalog with name and description', () async {
    writeSkill('release', 'How to cut a release');
    await settings.setTrusted(
      HostRepository.localHostId,
      workspace.path,
      trusted: true,
    );

    final snapshot = await loader.load(chat(), runtime, HostOs.posix);

    expect(snapshot.skills, hasLength(1));
    expect(snapshot.skills.single.name, 'release');
    expect(snapshot.skills.single.description, 'How to cut a release');
  });

  test('a workspace without instructions or skills needs no trust', () async {
    final snapshot = await loader.load(chat(), runtime, HostOs.posix);
    expect(snapshot.needsTrust, isFalse);
    expect(snapshot.agentsMd, isNull);
    expect(snapshot.skills, isEmpty);
  });
}
