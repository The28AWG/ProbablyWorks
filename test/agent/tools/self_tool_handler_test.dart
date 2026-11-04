import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/tools/self_tool_handler.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/saved_model_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/host/host_diagnostics.dart';
import 'package:probably_works/host/host_runtime_factory.dart';
import 'package:probably_works/host/ssh_connection_pool.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';

/// Каталог моделей здесь не используется: заглушка без сети.
class _NoNetworkLlm implements LlmProvider {
  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      throw UnsupportedError('no network in tests');

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];

  @override
  Future<LlmKeyInfo> checkKey() =>
      Future.value(const LlmKeyInfo(label: 'test', usage: 0));
}

void main() {
  late AppDatabase db;
  late HostRepository hosts;
  late SettingsRepository settings;
  late SelfToolHandler self;

  setUp(() async {
    db = openInMemoryDatabase();
    hosts = HostRepository(db);
    settings = SettingsRepository(db);
    await settings.preload();
    await hosts.ensureLocalHost(DateTime.now());
    final secrets = MemorySecretStore();
    final pool = SshConnectionPool(
      hosts,
      secrets,
      settings,
      HostKeyConfirmations(),
    );
    self = SelfToolHandler(
      hosts,
      settings,
      LocaleController(),
      ThemeController(),
      ModelCatalogService(SavedModelRepository(db), _NoNetworkLlm()),
      HostDiagnostics(
        hosts,
        secrets,
        settings,
        HostRuntimeFactory(pool, const PipePtyLauncher()),
      ),
    );
  });

  tearDown(() => db.close());

  group('host_add', () {
    test('rejects key paths the app cannot expand', () async {
      for (final keyPath in ['~bob/.ssh/id', r'$HOME/.ssh/id', 'keys/id']) {
        await expectLater(
          self.prepare(ToolNames.hostAdd, {
            'name': 'prod',
            'address': '10.0.0.5',
            'keyPath': keyPath,
          }),
          throwsA(isA<ArgumentError>()),
          reason: keyPath,
        );
      }
    });

    test('keyPath is only for key auth', () async {
      await expectLater(
        self.prepare(ToolNames.hostAdd, {
          'name': 'prod',
          'address': '10.0.0.5',
          'authType': 'password',
          'keyPath': '~/.ssh/id_ed25519',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects bad port and address', () async {
      await expectLater(
        self.prepare(ToolNames.hostAdd, {
          'name': 'prod',
          'address': '10.0.0.5',
          'port': 0,
        }),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        self.prepare(ToolNames.hostAdd, {
          'name': 'prod',
          'address': '10.0.0.5 extra',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'summary shows the target and key path; apply stores the host',
      () async {
        final change = await self.prepare(ToolNames.hostAdd, {
          'name': 'prod',
          'address': '10.0.0.5',
          'username': 'deploy',
          'keyPath': '~/.ssh/id_ed25519',
        });
        expect(change.summary, contains('prod'));
        expect(change.summary, contains('deploy@10.0.0.5:22'));
        expect(change.summary, contains('~/.ssh/id_ed25519'));
        expect(change.keyPath, '~/.ssh/id_ed25519');

        final result = await change.apply();
        final id = RegExp(r'id ([0-9a-f-]+)').firstMatch(result)!.group(1)!;
        final saved = (await hosts.byId(id))!;
        expect(saved.name, 'prod');
        expect(saved.keyPath, '~/.ssh/id_ed25519');
        expect(saved.authType, SshAuthType.key);
      },
    );
  });

  group('host_update', () {
    test('rejects fields that redirect or weaken the connection', () async {
      await expectLater(
        self.prepare(ToolNames.hostUpdate, {
          'id': HostRepository.localHostId,
          'address': '6.6.6.6',
        }),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        self.prepare(ToolNames.hostUpdate, {
          'id': HostRepository.localHostId,
          'hostKeyFingerprint': 'SHA256:x',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('needs at least one field', () async {
      await expectLater(
        self.prepare(ToolNames.hostUpdate, {'id': HostRepository.localHostId}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('empty notes clear them; rename keeps the other fields', () async {
      final first = await self.prepare(ToolNames.hostUpdate, {
        'id': HostRepository.localHostId,
        'name': 'Workstation',
        'notes': 'old notes',
      });
      await first.apply();

      final cleared = await self.prepare(ToolNames.hostUpdate, {
        'id': HostRepository.localHostId,
        'notes': '',
      });
      await cleared.apply();

      final host = (await hosts.byId(HostRepository.localHostId))!;
      expect(host.name, 'Workstation');
      expect(host.notes, isNull);
    });
  });

  group('settings', () {
    test('settings_read never exposes denylist or default policy', () async {
      final json = jsonDecode(
        await self.read(ToolNames.settingsRead, {}),
      ) as Map<String, dynamic>;
      expect(json.keys, isNot(contains('denylist')));
      expect(json.keys, isNot(contains('defaultPolicy')));
      expect(json.keys, contains('language'));
      expect(json.keys, contains('limits'));
    });

    test('settings_update rejects unknown keys and bad values', () async {
      final cases = [
        {'key': 'denylist', 'value': '.*'},
        {'key': 'language', 'value': 'de'},
        {'key': 'limits', 'value': '{not json'},
        {'key': 'stepsTools', 'value': 'everything'},
      ];
      for (final args in cases) {
        await expectLater(
          self.prepare(ToolNames.settingsUpdate, args),
          throwsA(isA<ArgumentError>()),
          reason: '$args',
        );
      }
    });

    test('settings_update applies a valid steps change', () async {
      final change = await self.prepare(ToolNames.settingsUpdate, {
        'key': 'stepsGroup',
        'value': 'no',
      });
      expect(change.summary, contains('stepsGroup'));
      await change.apply();
      expect((await settings.readStepsDisplay()).group, isFalse);
    });

    test('settings_update switches expand-while-running', () async {
      final change = await self.prepare(ToolNames.settingsUpdate, {
        'key': 'stepsExpandWhileActive',
        'value': 'no',
      });
      await change.apply();
      expect((await settings.readStepsDisplay()).expandWhileActive, isFalse);
      await expectLater(
        self.prepare(ToolNames.settingsUpdate, {
          'key': 'stepsExpandWhileActive',
          'value': 'maybe',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test('read tools reject unknown host ids', () async {
    await expectLater(
      self.read(ToolNames.hostTest, {'id': 'nope'}),
      throwsA(isA<ArgumentError>()),
    );
  });
}
