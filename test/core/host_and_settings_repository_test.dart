import 'package:command_shield/command_shield.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
import 'package:probably_works/agent/policy/command_risk.dart';
import 'package:probably_works/agent/policy/security_profile.dart';
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

  test('watch on pinned models emits after every save', () async {
    final settings = SettingsRepository(db);
    final values = <String?>[];
    final sub = settings
        .watch(SettingsRepository.keyPinnedModels)
        .listen(values.add);
    addTearDown(sub.cancel);

    await settings.savePinnedModels(['openai/gpt-4o']);
    await settings.savePinnedModels(const []);
    await pumpEventQueue();

    expect(values.last, '[]');
    expect(values, contains('["openai/gpt-4o"]'));
  });

  test('theme mode is stored by name and read back', () async {
    final settings = SettingsRepository(db);
    expect(await settings.read(SettingsRepository.keyThemeMode), isNull);

    await settings.write(SettingsRepository.keyThemeMode, 'dark');
    await settings.preload();

    expect(settings.cached(SettingsRepository.keyThemeMode), 'dark');
  });

  test(
    'preloaded settings answer synchronously and stay in sync on write',
    () async {
      final settings = SettingsRepository(db);
      await settings.write(SettingsRepository.keyDefaultModel, 'openai/gpt-4o');
      await settings.preload();

      expect(
        settings.cached(SettingsRepository.keyDefaultModel),
        'openai/gpt-4o',
      );

      await settings.write(
        SettingsRepository.keyDefaultModel,
        'anthropic/claude',
      );
      expect(
        settings.cached(SettingsRepository.keyDefaultModel),
        'anthropic/claude',
      );
      expect(
        await settings.read(SettingsRepository.keyDefaultModel),
        'anthropic/claude',
      );

      await settings.write(SettingsRepository.keyDefaultModel, null);
      expect(settings.cached(SettingsRepository.keyDefaultModel), isNull);
      expect(await settings.read(SettingsRepository.keyDefaultModel), isNull);
    },
  );

  test('preloaded steps, pins and limits match the stored values', () async {
    final settings = SettingsRepository(db);
    await settings.saveStepsDisplay(
      const StepsDisplay(group: false, tools: ToolsVisibility.expanded),
    );
    await settings.savePinnedModels(['openai/gpt-4o']);
    await settings.preload();

    expect(settings.cachedStepsDisplay(), await settings.readStepsDisplay());
    expect(settings.cachedPinnedModels(), ['openai/gpt-4o']);
    expect(
      settings.cachedLimits().toJson(),
      (await settings.limits()).toJson(),
    );
  });

  test(
    'security profile round-trips and a broken value stays baseline',
    () async {
      final settings = SettingsRepository(db);
      expect(
        (await settings.readSecurityProfile()).commands['ls'],
        CommandRisk.auto,
      );

      final changed = const SecurityProfile().withCategory(
        KnowledgeCategory.network,
        CommandRisk.deny,
      );
      await settings.saveSecurityProfile(changed);
      expect(await settings.readSecurityProfile(), changed);

      await settings.write(SettingsRepository.keySecurityProfile, '{');
      expect(await settings.readSecurityProfile(), const SecurityProfile());
    },
  );

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
      expandWhileActive: false,
      thoughts: ThoughtsVisibility.current,
      tools: ToolsVisibility.active,
    );

    await settings.saveStepsDisplay(display);
    expect(await settings.readStepsDisplay(), display);

    await settings.write(SettingsRepository.keyStepsThoughts, 'bogus');
    await settings.write(SettingsRepository.keyStepsTools, null);
    expect(
      await settings.readStepsDisplay(),
      const StepsDisplay(
        group: false,
        expandWhileActive: false,
        thoughts: ThoughtsVisibility.all,
      ),
    );
  });
}
