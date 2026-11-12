import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_declarative_http_core/declarative_http_plugin.dart';
import 'package:test/test.dart';

final class _Settings implements PluginSettings {
  _Settings(this.value);

  Map<String, Object?> value;

  @override
  Future<Map<String, Object?>> read() async => value;

  @override
  Future<void> save(Map<String, Object?> value) async => this.value = value;
}

final class _Host implements PluginHost {
  _Host(this.response);

  final PluginHttpResult response;
  String? method;
  String? url;
  Map<String, String>? headers;
  Object? body;

  @override
  String get chatId => 'chat';

  @override
  String get cwd => '/tmp';

  @override
  Future<PluginCommandResult> runCommand(
    String executable,
    List<String> args, {
    Duration? timeout,
  }) => throw UnsupportedError('command is not used in this test');

  @override
  Future<PluginHttpResult> httpRequest({
    required String method,
    required String url,
    Map<String, String> headers = const {},
    Object? body,
    Duration? timeout,
  }) async {
    this.method = method;
    this.url = url;
    this.headers = headers;
    this.body = body;
    return response;
  }
}

Map<String, Object?> _tool({
  String method = 'GET',
  String url = 'https://api.test/items',
  Map<String, String> headers = const {},
  Object? body,
  String format = 'text',
  String? jsonPath,
  String? htmlSelector,
  int maxChars = 20000,
}) {
  final tool = <String, Object?>{
    'id': 'one',
    'title': 'One',
    'description': 'Test',
    'method': method,
    'url': url,
    'headers': headers,
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
    },
    'responseFormat': format,
    'maxResponseChars': maxChars,
  };
  if (body != null) tool['body'] = body;
  if (jsonPath != null) tool['jsonPath'] = jsonPath;
  if (htmlSelector != null) tool['htmlSelector'] = htmlSelector;
  return tool;
}

Future<PluginTool> _build(Map<String, Object?> tool) async {
  final settings = _Settings({
    'version': 1,
    'tools': [tool],
  });
  const plugin = DeclarativeHttpPlugin();
  final tools = await plugin.createTools(settings);
  return tools.single;
}

void main() {
  test('substitutes URL, headers and body', () async {
    final host = _Host(
      const PluginHttpResult(
        statusCode: 200,
        body: '{"items":[{"name":"A"},{"name":"B"}]}',
      ),
    );
    final tool = await _build(
      _tool(
        method: 'POST',
        url: 'https://api.test/items/{{id}}?q={{query}}',
        headers: {'X-Id': '{{id}}'},
        body: {'id': '{{id}}'},
      ),
    );

    await tool.run({'id': '1', 'query': 'a b'}, host);

    expect(host.method, 'POST');
    expect(host.url, 'https://api.test/items/1?q=a%20b');
    expect(host.headers?['X-Id'], '1');
    expect(host.body, {'id': '1'});
  });

  test('selects values from JSON with JSONPath', () async {
    final host = _Host(
      const PluginHttpResult(
        statusCode: 200,
        body: '{"items":[{"name":"A"},{"name":"B"}]}',
      ),
    );
    final tool = await _build(
      _tool(format: 'json', jsonPath: r'$.items[*].name'),
    );

    final result = await tool.run(const {}, host);

    expect(result.isError, isFalse);
    expect(result.text, contains('A'));
    expect(result.text, contains('B'));
  });

  test('extracts HTML text with a CSS selector', () async {
    final host = _Host(
      const PluginHttpResult(
        statusCode: 200,
        body: '<html><body><article><h2>Title</h2></article></body></html>',
      ),
    );
    final tool = await _build(_tool(format: 'html', htmlSelector: 'article'));

    final result = await tool.run(const {}, host);

    expect(result.isError, isFalse);
    expect(result.text, contains('Title'));
  });

  test('returns status and body for an HTTP error', () async {
    final host = _Host(
      const PluginHttpResult(statusCode: 404, body: 'not found', isError: true),
    );
    final tool = await _build(_tool());

    final result = await tool.run(const {}, host);

    expect(result.isError, isTrue);
    expect(result.text, contains('404'));
    expect(result.text, contains('not found'));
  });

  test('missing argument is an error', () async {
    final tool = await _build(_tool(url: 'https://api.test/{{id}}'));

    final result = await tool.run(
      const {},
      _Host(const PluginHttpResult(statusCode: 200, body: 'ok')),
    );

    expect(result.isError, isTrue);
    expect(result.text, contains('missing argument'));
  });
}
