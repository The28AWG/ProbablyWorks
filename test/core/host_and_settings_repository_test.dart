import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/host.dart';

void main() {
  late AppDatabase db;
  late HostRepository hosts;
  final now = DateTime(2026, 11, 1);

  setUp(() {
    db = openInMemoryDatabase();
    hosts = HostRepository(db);
  });

  tearDown(() => db.close());

  Host sshHost() => Host(
    id: 'h1',
    name: 'srv',
    kind: HostKind.ssh,
    address: '10.0.0.1',
    port: 2222,
    username: 'deploy',
    defaultWorkspace: '/srv/app',
    shellOverride: 'bash',
    notes: 'prod API box',
    connectTimeoutSeconds: 7,
    createdAt: now,
    updatedAt: now,
  );

  test(
    'host keeps notes, workspace, shell override and connect timeout',
    () async {
      await hosts.save(sshHost());

      final loaded = (await hosts.byId('h1'))!;

      expect(loaded.defaultWorkspace, '/srv/app');
      expect(loaded.shellOverride, 'bash');
      expect(loaded.notes, 'prod API box');
      expect(loaded.connectTimeoutSeconds, 7);
      expect(loaded.lastCheckAt, isNull);
    },
  );

  test(
    'recordCheck stores latency and error without touching other fields',
    () async {
      await hosts.save(sshHost());
      final checkedAt = DateTime(2026, 11, 1, 12);

      await hosts.recordCheck('h1', at: checkedAt, latencyMs: 42);
      final ok = (await hosts.byId('h1'))!;
      expect(ok.lastLatencyMs, 42);
      expect(ok.lastCheckError, isNull);
      expect(ok.lastCheckAt, checkedAt);
      expect(ok.defaultWorkspace, '/srv/app');

      await hosts.recordCheck('h1', at: checkedAt, error: 'timeout');
      final failed = (await hosts.byId('h1'))!;
      expect(failed.lastLatencyMs, isNull);
      expect(failed.lastCheckError, 'timeout');
      expect(failed.notes, 'prod API box');
    },
  );

  test('pinned models round-trip and default to an empty list', () async {
    final settings = SettingsRepository(db);
    expect(await settings.readPinnedModels(), isEmpty);

    await settings.savePinnedModels(['openai/gpt-4o', 'anthropic/claude']);

    expect(await settings.readPinnedModels(), [
      'openai/gpt-4o',
      'anthropic/claude',
    ]);
  });

  test('steps display defaults to grouped, all thoughts, all tools', () async {
    final settings = SettingsRepository(db);
    expect(await settings.readStepsDisplay(), StepsDisplay.defaults);
  });

  test('steps display keeps the expanded mode across restarts', () async {
    final settings = SettingsRepository(db);
    const display = StepsDisplay(
      thoughts: ThoughtsVisibility.expanded,
      tools: ToolsVisibility.expanded,
    );

    await settings.saveStepsDisplay(display);
    expect(await settings.readStepsDisplay(), display);
  });

  test('steps display round-trips and ignores unknown stored values', () async {
    final settings = SettingsRepository(db);
    const display = StepsDisplay(
      group: false,
      thoughts: ThoughtsVisibility.current,
      tools: ToolsVisibility.active,
    );

    await settings.saveStepsDisplay(display);
    expect(await settings.readStepsDisplay(), display);

    await settings.write(SettingsRepository.keyStepsThoughts, 'bogus');
    await settings.write(SettingsRepository.keyStepsTools, null);
    expect(
      await settings.readStepsDisplay(),
      const StepsDisplay(group: false, thoughts: ThoughtsVisibility.all),
    );
  });
}
