import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:pw_client/pw_client.dart';
import 'package:test/test.dart';

final class _CapturingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(Stream.value(const <int>[]), 200);
  }
}

void main() {
  test('sends client metadata and a request id with every request', () async {
    final client = _CapturingClient();
    final api = RemoteAgentApi(
      baseUri: Uri.parse('http://127.0.0.1:1'),
      token: 'token',
      client: client,
      clientHeaders: const {
        'x-client-app': 'ProbablyWorks',
        'x-client-version': '1.2.3',
        'x-client-build': '42',
      },
    );
    addTearDown(api.dispose);

    await api.checkConnection();

    final request = client.requests.single;
    expect(request.headers['x-client-app'], 'ProbablyWorks');
    expect(request.headers['x-client-version'], '1.2.3');
    expect(request.headers['x-client-build'], '42');
    expect(request.headers['x-request-id'], isNotEmpty);
  });
}
