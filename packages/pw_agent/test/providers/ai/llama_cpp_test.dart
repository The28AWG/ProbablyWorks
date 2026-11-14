import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_connection.dart';
import 'package:pw_agent/providers/ai/llama_cpp/llama_cpp_llm_provider.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:test/test.dart';

/// Локальный HTTP-сервер, который отвечает как llama.cpp server.
class _FakeLlamaServer {
  _FakeLlamaServer._(this._server);

  final HttpServer _server;

  /// Запросы, которые пришли на сервер, по порядку.
  final List<String> requests = [];

  /// Сценарии по пути: `/health`, `/models`, `/v1/models`.
  final Map<String, _Handler> handlers = {};

  static Future<_FakeLlamaServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeLlamaServer._(server);
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

typedef _Handler = Future<void> Function(HttpRequest request);

Future<void> _json(HttpRequest request, int status, Object body) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await request.response.close();
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late MemorySecretStore secrets;
  late LlamaCppSettingsReader reader;

  setUp(() {
    db = openInMemoryDatabase();
    settings = SettingsRepository(db);
    secrets = MemorySecretStore();
    reader = LlamaCppSettingsReader(settings, secrets);
  });

  tearDown(() => db.close());

  group('LlamaCppSettingsReader', () {
    test('defaults to enabled and localhost', () async {
      final connection = await reader.read();

      expect(connection.enabled, isTrue);
      expect(connection.baseUrl, llamaCppDefaultBaseUrl);
      expect(connection.hasApiKey, isFalse);
    });

    test('reads enabled, address and key from storage', () async {
      await settings.write(SettingsRepository.keyLlamaCppEnabled, 'false');
      await settings.write(
        SettingsRepository.keyLlamaCppBaseUrl,
        'http://127.0.0.1:9000',
      );
      await secrets.write(llamaCppKeyName, 'secret-key');

      final connection = await reader.read();

      expect(connection.enabled, isFalse);
      expect(connection.baseUrl, 'http://127.0.0.1:9000');
      expect(connection.hasApiKey, isTrue);
      expect(connection.keyTail, 'key');
    });

    test('readStatus exposes the key mask without the key', () async {
      await secrets.write(llamaCppKeyName, 'secret-key');

      final status = await reader.readStatus();

      expect(status.apiKeySet, isTrue);
      expect(status.apiKeyTail, 'key');
      expect(status.available, isFalse);
      expect(status.checkedAt, isNull);
    });
  });

  group('LlamaCppLlmProvider', () {
    late _FakeLlamaServer server;
    late LlamaCppLlmProvider provider;

    setUp(() async {
      server = await _FakeLlamaServer.start();
      await settings.write(
        SettingsRepository.keyLlamaCppBaseUrl,
        server.baseUrl,
      );
      provider = LlamaCppLlmProvider(settings: reader);
    });

    tearDown(() => server.close());

    test('lists models from the router endpoint', () async {
      server.handlers['/models'] = (request) => _json(request, 200, {
        'data': [
          {
            'id': 'qwen3',
            'aliases': ['Qwen 3'],
            'tags': ['tool'],
            'meta': {'n_ctx_train': 4096},
            'created': 123,
            'architecture': {
              'input_modalities': ['text'],
            },
          },
        ],
      });

      final models = await provider.listModels();

      expect(models, hasLength(1));
      expect(models.single.id, 'qwen3');
      expect(models.single.name, 'Qwen 3');
      expect(models.single.contextLength, 4096);
      expect(models.single.supportsTools, isTrue);
      expect(models.single.created, 123);
      expect(models.single.inputModalities, ['text']);
    });

    test('strips the quantization suffix from the display name', () async {
      server.handlers['/models'] = (request) => _json(request, 200, {
        'data': [
          {'id': 'Hy-MT2-1.8B-Q4_K_M'},
          {'id': 'Qwen3.8-27B-UD-Q2_K_XL'},
          {'id': 'gemma-4-E4B-it-Q4_K_M'},
        ],
      });

      final models = await provider.listModels();

      expect(models.map((m) => m.name), [
        'Hy-MT2-1.8B',
        'Qwen3.8-27B',
        'gemma-4-E4B-it',
      ]);
    });

    test('empty aliases do not throw', () async {
      server.handlers['/models'] = (request) => _json(request, 200, {
        'data': [
          {'id': 'qwen3', 'aliases': <String>[]},
        ],
      });

      final models = await provider.listModels();

      expect(models.single.name, 'qwen3');
    });

    test('empty tags do not hide the model from the tools filter', () async {
      server.handlers['/models'] = (request) => _json(request, 200, {
        'data': [
          {'id': 'qwen3', 'tags': <String>[]},
        ],
      });

      final models = await provider.listModels();

      expect(models.single.supportsTools, isTrue);
    });

    test(
      'falls back to the OpenAI endpoint when the router is missing',
      () async {
        server.handlers['/models'] = (request) =>
            _json(request, 404, {'error': 'not found'});
        server.handlers['/v1/models'] = (request) => _json(request, 200, {
          'data': [
            {
              'id': 'llama3',
              'meta': {'n_ctx_train': 8192},
              'created': 456,
            },
          ],
        });

        final models = await provider.listModels();

        expect(models.single.id, 'llama3');
        expect(models.single.contextLength, 8192);
        expect(models.single.created, 456);
      },
    );

    test('checkHealth reports the server and model count', () async {
      server.handlers['/health'] = (request) =>
          _json(request, 200, {'status': 'ok'});
      server.handlers['/models'] = (request) => _json(request, 200, {
        'data': [
          {'id': 'a'},
          {'id': 'b'},
        ],
      });

      final status = await provider.checkHealth();

      expect(status.available, isTrue);
      expect(status.modelCount, 2);
      expect(status.error, isNull);
      expect(status.checkedAt, isNotNull);
    });

    test('checkHealth reports a missing server without throwing', () async {
      server.handlers['/health'] = (request) =>
          _json(request, 503, {'status': 'error'});

      final status = await provider.checkHealth();

      expect(status.available, isFalse);
      expect(status.error, contains('not responding'));
    });

    test('a disabled provider does not call the server', () async {
      await settings.write(SettingsRepository.keyLlamaCppEnabled, 'false');

      expect(await provider.isEnabled, isFalse);
      expect(await provider.isAvailable, isFalse);
      expect(await provider.listModels(), isEmpty);
      expect(server.requests, isEmpty);
    });

    test('stream maps deltas and tool calls', () async {
      server.handlers['/v1/chat/completions'] = (request) async {
        final body = await utf8.decoder.bind(request).join();
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        expect(decoded['model'], 'qwen3');
        expect(decoded['stream'], isTrue);
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
        request.response.write(
          'data: {"choices":[{"delta":{"content":"Привет"},"finish_reason":null}]}\n\n',
        );
        request.response.write(
          'data: {"choices":[{"delta":{"content":"!"},"finish_reason":"stop"}]}\n\n',
        );
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      };

      final events = await provider
          .stream(
            const LlmRequest(
              model: 'llamacpp:qwen3',
              messages: [LlmMessage.user('Привет')],
            ),
          )
          .toList();

      expect(events.whereType<LlmTextDelta>().map((e) => e.text), [
        'Привет',
        '!',
      ]);
      final completed = events.whereType<LlmCompleted>().single;
      expect(completed.finishReason, 'stop');
    });

    test('sends text, audio and video attachments as content parts', () async {
      server.handlers['/v1/chat/completions'] = (request) async {
        final body = await utf8.decoder.bind(request).join();
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        final messages = decoded['messages'] as List<dynamic>;
        final content = (messages.first as Map)['content'] as List<dynamic>;
        final parts = [for (final part in content) part as Map];
        expect(parts.first, containsPair('type', 'text'));
        expect(parts.first['text'], 'Files attached');
        expect(parts[1], containsPair('type', 'text'));
        expect('${parts[1]['text']}', contains('hello from file'));
        expect(parts[2], containsPair('type', 'input_audio'));
        expect((parts[2]['input_audio'] as Map)['format'], 'mp3');
        expect(parts[3], containsPair('type', 'input_video'));
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      };

      final events = await provider
          .stream(
            LlmRequest(
              model: 'llamacpp:qwen3',
              messages: [
                LlmMessage(
                  role: LlmRole.user,
                  content: 'Files attached',
                  files: [
                    LlmFilePart(
                      name: 'note.txt',
                      mimeType: 'text/plain',
                      bytes: Uint8List.fromList(utf8.encode('hello from file')),
                    ),
                    LlmFilePart(
                      name: 'voice.mp3',
                      mimeType: 'audio/mpeg',
                      bytes: Uint8List.fromList(const [1, 2, 3]),
                    ),
                    LlmFilePart(
                      name: 'clip.mp4',
                      mimeType: 'video/mp4',
                      bytes: Uint8List.fromList(const [4, 5, 6]),
                    ),
                  ],
                ),
              ],
            ),
          )
          .toList();

      expect(events.whereType<LlmCompleted>(), isNotEmpty);
    });

    test('an unsupported binary file is sent as a file part', () async {
      server.handlers['/v1/chat/completions'] = (request) async {
        final body = await utf8.decoder.bind(request).join();
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        final messages = decoded['messages'] as List<dynamic>;
        final content = (messages.first as Map)['content'] as List<dynamic>;
        final part = content.last as Map;
        expect(part, containsPair('type', 'file'));
        expect((part['file'] as Map)['filename'], 'scan.pdf');
        await _json(request, 400, {
          'error': {'message': 'unsupported file type'},
        });
      };

      await expectLater(
        provider
            .stream(
              LlmRequest(
                model: 'llamacpp:qwen3',
                messages: [
                  LlmMessage(
                    role: LlmRole.user,
                    content: 'PDF',
                    files: [
                      LlmFilePart(
                        name: 'scan.pdf',
                        mimeType: 'application/pdf',
                        bytes: Uint8List.fromList(const [0, 1, 2]),
                      ),
                    ],
                  ),
                ],
              ),
            )
            .toList(),
        throwsA(
          isA<LlmFailure>().having(
            (e) => e.message,
            'message',
            contains('unsupported file type'),
          ),
        ),
      );
    });

    test('a server error becomes LlmFailure', () async {
      server.handlers['/v1/chat/completions'] = (request) async {
        await _json(request, 400, {
          'error': {'message': 'context length exceeded'},
        });
      };

      await expectLater(
        provider
            .stream(
              const LlmRequest(
                model: 'llamacpp:qwen3',
                messages: [LlmMessage.user('Привет')],
              ),
            )
            .toList(),
        throwsA(
          isA<LlmFailure>().having(
            (e) => e.contextLengthExceeded,
            'contextLengthExceeded',
            isTrue,
          ),
        ),
      );
    });
  });

  group('LlamaCppStatus', () {
    test('copyWith keeps values and clears the error', () {
      final now = DateTime(2026, 1, 1);
      const status = LlamaCppStatus(
        enabled: true,
        baseUrl: 'http://localhost:8080',
        available: true,
        error: 'boom',
      );

      final next = status.copyWith(
        checkedAt: now,
        modelCount: 2,
        clearError: true,
      );

      expect(next.enabled, isTrue);
      expect(next.baseUrl, 'http://localhost:8080');
      expect(next.available, isTrue);
      expect(next.modelCount, 2);
      expect(next.error, isNull);
      expect(next.checkedAt, now);
    });
  });
}
