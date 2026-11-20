import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pw_server/pw_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late StaticWeb web;
  late HttpServer server;
  late HttpClient client;
  late String base;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('pw_static_web_');
    File(p.join(temp.path, 'index.html'))
        .writeAsStringSync('<html>index</html>');
    Directory(p.join(temp.path, 'assets')).createSync();
    File(p.join(temp.path, 'assets', 'app.js'))
        .writeAsStringSync('console.log(1);');
    File(p.join(temp.path, 'assets', 'style.css')).writeAsStringSync('body{}');
    File(p.join(temp.path, 'main.dart.mjs')).writeAsStringSync('export {};');
    File(p.join(temp.path, 'main.dart.js_1.part.js'))
        .writeAsStringSync('console.log(2);');
    File(p.join(temp.path, 'main.dart_module1.wasm'))
        .writeAsBytesSync([0, 97, 115, 109]);
    Directory(p.join(temp.path, 'canvaskit')).createSync();
    File(p.join(temp.path, 'canvaskit', 'canvaskit.wasm'))
        .writeAsBytesSync([0, 97, 115, 109]);
    web = StaticWeb.open(temp.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((request) async {
        await web.serve(request, request.response);
        await request.response.close();
      });
    base = 'http://127.0.0.1:${server.port}';
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    temp.deleteSync(recursive: true);
  });

  test('serves index.html for the root', () async {
    final response = await _request(client, base, '/');

    expect(response.status, HttpStatus.ok);
    expect(response.body, contains('index'));
    expect(response.headers.value(HttpHeaders.cacheControlHeader), 'no-cache');
    expect(response.headers.value('x-content-type-options'), 'nosniff');
  });

  test('serves static files with their content type', () async {
    final response = await _request(client, base, '/assets/app.js');

    expect(response.status, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'text/javascript');
    expect(response.body, 'console.log(1);');
    expect(
      response.headers.value(HttpHeaders.cacheControlHeader),
      'public, max-age=3600',
    );
  });

  test('serves wasm with application/wasm', () async {
    final response = await _request(client, base, '/canvaskit/canvaskit.wasm');

    expect(response.status, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'application/wasm');
  });

  test('serves the wasm module loader as JavaScript', () async {
    final response = await _request(client, base, '/main.dart.mjs');

    expect(response.status, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'text/javascript');
    expect(response.body, 'export {};');
  });

  test('serves deferred JS parts as JavaScript without caching', () async {
    final response = await _request(client, base, '/main.dart.js_1.part.js');

    expect(response.status, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'text/javascript');
    expect(response.body, 'console.log(2);');
    expect(response.headers.value(HttpHeaders.cacheControlHeader), 'no-cache');
  });

  test('serves deferred Wasm modules as application/wasm', () async {
    final response = await _request(client, base, '/main.dart_module1.wasm');

    expect(response.status, HttpStatus.ok);
    expect(response.headers.contentType?.mimeType, 'application/wasm');
    expect(response.headers.value(HttpHeaders.cacheControlHeader), 'no-cache');
  });

  test('enables cross-origin isolation for HTML documents', () async {
    for (final path in ['/', '/a/profile/chats']) {
      final response = await _request(client, base, path);

      expect(response.status, HttpStatus.ok, reason: 'path $path');
      expect(
        response.headers.value('cross-origin-opener-policy'),
        'same-origin',
        reason: 'path $path',
      );
      expect(
        response.headers.value('cross-origin-embedder-policy'),
        'require-corp',
        reason: 'path $path',
      );
    }
  });

  test('does not add cross-origin isolation to assets', () async {
    final response = await _request(client, base, '/assets/app.js');

    expect(response.headers.value('cross-origin-opener-policy'), isNull);
  });

  test('falls back to index.html for an extensionless route', () async {
    final response = await _request(client, base, '/a/profile/chats');

    expect(response.status, HttpStatus.ok);
    expect(response.body, contains('index'));
  });

  test('does not fall back for a missing file with an extension', () async {
    final response = await _request(client, base, '/missing.js');

    expect(response.status, HttpStatus.notFound);
    expect(response.body, isNot(contains('index')));
  });

  test('does not fall back for a missing asset', () async {
    final response = await _request(client, base, '/assets/missing');

    expect(response.status, HttpStatus.notFound);
  });

  test('rejects traversal and encoded separators', () async {
    for (final path in ['/..%2fsecret', '/%2e%2e%2fsecret', '/a//b']) {
      final response = await _request(client, base, path);
      expect(
        response.status,
        HttpStatus.notFound,
        reason: 'path $path must not be served',
      );
    }
  });

  test('does not follow symlinks outside the web root', () async {
    if (Platform.isWindows) return;
    final outside = File(
      p.join(
        temp.parent.path,
        'pw_static_secret_${DateTime.now().microsecondsSinceEpoch}.txt',
      ),
    )..writeAsStringSync('secret');
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync();
    });
    Link(p.join(temp.path, 'leak.txt')).createSync(outside.path);

    final response = await _request(client, base, '/leak.txt');

    expect(response.status, HttpStatus.notFound);
    expect(response.body, isNot(contains('secret')));
  });

  test('supports HEAD without a body', () async {
    final response = await _request(client, base, '/', method: 'HEAD');

    expect(response.status, HttpStatus.ok);
    expect(response.body, isEmpty);
    expect(response.headers.contentLength, greaterThan(0));
  });

  test('answers conditional requests with 304', () async {
    final first = await _request(client, base, '/assets/app.js');
    final etag = first.headers.value(HttpHeaders.etagHeader);
    expect(etag, isNotNull);

    final second = await _request(
      client,
      base,
      '/assets/app.js',
      headers: {HttpHeaders.ifNoneMatchHeader: etag!},
    );

    expect(second.status, HttpStatus.notModified);
    expect(second.body, isEmpty);
  });

  test('rejects unsupported methods', () async {
    final response = await _request(client, base, '/', method: 'POST');

    expect(response.status, HttpStatus.methodNotAllowed);
    expect(response.headers.value(HttpHeaders.allowHeader), 'GET, HEAD');
  });

  test('requires index.html when opening a web directory', () {
    final empty = Directory.systemTemp.createTempSync('pw_static_empty_');
    addTearDown(() => empty.deleteSync(recursive: true));

    expect(() => StaticWeb.open(empty.path), throwsFormatException);
  });
}

Future<_Response> _request(
  HttpClient client,
  String base,
  String path, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) async {
  final request = await client.openUrl(method, Uri.parse('$base$path'));
  headers.forEach(request.headers.set);
  final response = await request.close();
  final body = await utf8.decoder.bind(response).join();
  return _Response(
    status: response.statusCode,
    headers: response.headers,
    body: body,
  );
}

final class _Response {
  const _Response({
    required this.status,
    required this.headers,
    required this.body,
  });

  final int status;
  final HttpHeaders headers;
  final String body;
}
