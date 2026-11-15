import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_model_runtime.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';
import 'package:test/test.dart';

typedef _Handler = Future<void> Function(HttpRequest request);

/// Небольшой HTTP-сервер с теми же путями, что у llama.cpp router.
final class _FakeLlama {
  _FakeLlama._(this._server);

  final HttpServer _server;
  final handlers = <String, _Handler>{};
  final requests = <String>[];

  static Future<_FakeLlama> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeLlama._(server);
    server.listen((request) async {
      fake.requests.add('${request.method} ${request.uri.path}');
      final handler = fake.handlers[request.uri.path];
      if (handler == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      await handler(request);
    });
    return fake;
  }

  String get baseUrl => 'http://${_server.address.host}:${_server.port}';

  Future<void> close() => _server.close(force: true);
}

Future<void> _json(HttpRequest request, int status, Object body) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await request.response.close();
}

LlamaCppModelRuntime _runtime(_FakeLlama server) => LlamaCppModelRuntime(
  readConfig: () async =>
      LlmProviderConfig(enabled: true, baseUrl: server.baseUrl),
  requestTimeout: const Duration(seconds: 2),
);

Map<String, Object?> _model(
  String id, {
  required String status,
  Map<String, Object?>? progress,
}) => {
  'id': id,
  'status': {
    'value': status,
    ...?progress == null ? null : {'progress': progress},
  },
};

void main() {
  late _FakeLlama server;
  late LlamaCppModelRuntime runtime;

  setUp(() async {
    server = await _FakeLlama.start();
    runtime = _runtime(server);
  });

  tearDown(() => server.close());

  test('reads router state from /models', () async {
    server.handlers['/models'] = (request) => _json(request, 200, {
      'data': [
        _model('ready', status: 'loaded'),
        _model(
          'loading',
          status: 'loading',
          progress: {
            'stages': ['text_model', 'mmproj_model'],
            'current': 'text_model',
            'value': 0.5,
          },
        ),
      ],
    });

    final state = await runtime.snapshotRuntime();

    expect(state.capabilities.reportsProgress, isTrue);
    expect(state.models['llamacpp:ready']?.phase, ModelRuntimePhase.loaded);
    final loading = state.models['llamacpp:loading'];
    expect(loading?.phase, ModelRuntimePhase.loading);
    // В снимке `/models` этап и проценты загрузки не передаются: только SSE.
    expect(loading?.progress, isNull);
  });

  test('turns SSE loading events into progress and completed state', () async {
    server.handlers['/models'] = (request) => _json(request, 200, {
      'data': [_model('qwen', status: 'unloaded')],
    });
    server.handlers['/models/sse'] = (request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
      request.response.write(
        'data: ${jsonEncode({
          'model': 'qwen',
          'event': 'model_status',
          'data': {
            'status': 'loading',
            'progress': {
              'stages': ['text_model'],
              'current': 'text_model',
              'value': 0.5,
            },
          },
        })}\n\n',
      );
      request.response.write(
        'data: ${jsonEncode({
          'model': 'qwen',
          'event': 'model_status',
          'data': {'status': 'loaded'},
        })}\n\n',
      );
      await request.response.close();
    };

    final states = await runtime.watchRuntime().take(3).toList();

    expect(states, hasLength(3));
    expect(states[1].models['llamacpp:qwen']?.phase, ModelRuntimePhase.loading);
    expect(states[1].models['llamacpp:qwen']?.progress?.fraction, 0.5);
    expect(states[2].models['llamacpp:qwen']?.phase, ModelRuntimePhase.loaded);
  });

  test('sends load and unload requests by local id', () async {
    server.handlers['/models/load'] = (request) async {
      final body = await utf8.decoder.bind(request).join();
      expect(jsonDecode(body), {'model': 'qwen'});
      await _json(request, 200, {'success': true});
    };
    server.handlers['/models/unload'] = (request) async {
      final body = await utf8.decoder.bind(request).join();
      expect(jsonDecode(body), {'model': 'qwen'});
      await _json(request, 200, {'success': true});
    };

    await runtime.loadRuntimeModel('qwen');
    await runtime.unloadRuntimeModel('qwen');

    expect(server.requests, contains('POST /models/load'));
    expect(server.requests, contains('POST /models/unload'));
  });

  test(
    'falls back to single-model health and does not offer control',
    () async {
      server.handlers['/models'] = (request) => _json(request, 404, {
        'error': {'message': 'not found'},
      });
      server.handlers['/health'] = (request) =>
          _json(request, 200, {'status': 'ok'});
      server.handlers['/v1/models'] = (request) => _json(request, 200, {
        'data': [
          {'id': 'llama3'},
        ],
      });

      final state = await runtime.snapshotRuntime();

      expect(state.capabilities.reportsState, isTrue);
      expect(state.capabilities.canLoad, isFalse);
      expect(state.capabilities.canUnload, isFalse);
      expect(state.models['llamacpp:llama3']?.phase, ModelRuntimePhase.loaded);
    },
  );
}
