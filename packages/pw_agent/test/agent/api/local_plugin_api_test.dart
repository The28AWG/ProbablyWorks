import 'package:plugin_api/plugin_api.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/local_plugin_api.dart';
import 'package:pw_agent/agent/plugins/plugin_service.dart';
import 'package:pw_agent/src/agent/loop/agent_hub.dart';
import 'package:test/test.dart';

final class _TestPlugin implements Plugin {
  const _TestPlugin(this.id, {this.dependsOn = const {}});

  @override
  final String id;

  @override
  final Set<String> dependsOn;

  @override
  bool get defaultEnabled => false;

  @override
  Future<List<PluginTool>> createTools(PluginSettings settings) async =>
      const [];
}

final class _FakeService implements PluginService {
  final calls = <String>[];

  @override
  List<Plugin> get all => const [
    _TestPlugin('first'),
    _TestPlugin('second', dependsOn: {'first'}),
  ];

  @override
  Set<String> get enabledIds => const {'first'};

  @override
  Set<String> missingDependencies(String id, {Set<String>? enabled}) =>
      id == 'second' ? const {'first'} : const {};

  @override
  Set<String> dependents(String id, {Set<String>? enabled}) =>
      id == 'first' ? const {'second'} : const {};

  @override
  Future<void> enable(Set<String> ids) async {
    calls.add('enable:${ids.join(',')}');
  }

  @override
  Future<void> disable(Set<String> ids) async {
    calls.add('disable:${ids.join(',')}');
  }

  @override
  PluginSettings settingsFor(String id) => const _NoopSettings();

  @override
  Future<void> refresh() => Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used by the plugin API');
}

final class _NoopSettings implements PluginSettings {
  const _NoopSettings();

  @override
  Future<Map<String, Object?>> read() async => const {};

  @override
  Future<void> save(Map<String, Object?> value) => Future<void>.value();
}

final class _FakeHub implements AgentHub {
  @override
  final runningChatIds = <String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not used by the plugin API');
}

void main() {
  late _FakeService service;
  late _FakeHub hub;
  late LocalPluginApi api;

  setUp(() {
    service = _FakeService();
    hub = _FakeHub();
    api = LocalPluginApi(service, hub);
  });

  test('maps plugins and enabled state into a snapshot', () async {
    final snapshot = await api.pluginSnapshot();

    expect(snapshot.plugins.map((plugin) => plugin.id), ['first', 'second']);
    expect(snapshot.enabled, {'first'});
  });

  test('delegates plugin changes when the agent is idle', () async {
    await api.setEnabled({'first', 'second'}, enabled: false);

    expect(service.calls, ['disable:first,second']);
  });

  test('rejects plugin changes while a chat is running', () async {
    hub.runningChatIds.add('chat');

    await expectLater(
      api.setEnabled({'first'}, enabled: false),
      throwsA(
        isA<AgentApiException>()
            .having((error) => error.status, 'status', 409)
            .having((error) => error.code, 'code', 'agent_busy'),
      ),
    );
    expect(service.calls, isEmpty);
  });
}
