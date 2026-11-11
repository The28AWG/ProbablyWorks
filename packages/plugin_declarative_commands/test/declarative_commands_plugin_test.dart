import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_declarative_commands/declarative_commands_plugin.dart';

final class _Settings implements PluginSettings {
  _Settings(this.value);

  Map<String, Object?> value;

  @override
  Future<Map<String, Object?>> read() async => value;

  @override
  Future<void> save(Map<String, Object?> value) async => this.value = value;
}

final class _Host implements PluginHost {
  String? executable;
  List<String>? args;
  Duration? timeout;

  @override
  String get chatId => 'chat';

  @override
  String get cwd => '/tmp';

  @override
  Future<PluginCommandResult> runCommand(
    String executable,
    List<String> args, {
    Duration? timeout,
  }) async {
    this.executable = executable;
    this.args = args;
    this.timeout = timeout;
    return const PluginCommandResult(output: 'ok', exitCode: 0);
  }

  @override
  Future<PluginHttpResult> httpRequest({
    required String method,
    required String url,
    Map<String, String> headers = const {},
    Object? body,
    Duration? timeout,
  }) => throw UnsupportedError('HTTP is not used in this test');
}

void main() {
  test('turns a fixed command into a plugin tool', () async {
    final settings = _Settings({
      'version': 1,
      'commands': [
        {
          'id': 'status',
          'title': 'Status',
          'description': 'Shows status',
          'executable': 'git',
          'args': ['status', '--short'],
          'timeoutSeconds': 12,
        },
      ],
    });
    const plugin = DeclarativeCommandsPlugin();
    final tools = await plugin.createTools(settings);

    expect(tools, hasLength(1));
    expect(tools.single.name, 'status');
    expect(tools.single.title, 'Status');

    final host = _Host();
    final result = await tools.single.run(const {}, host);

    expect(result.text, 'ok');
    expect(host.executable, 'git');
    expect(host.args, ['status', '--short']);
    expect(host.timeout, const Duration(seconds: 12));
  });

  test('ignores malformed commands', () async {
    final settings = _Settings({
      'commands': [
        {'id': '', 'executable': ''},
        'not a map',
      ],
    });
    const plugin = DeclarativeCommandsPlugin();
    final tools = await plugin.createTools(settings);

    expect(tools, isEmpty);
  });
}
