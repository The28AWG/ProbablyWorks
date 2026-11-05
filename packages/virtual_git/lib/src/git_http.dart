import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Ответ транспорта git по HTTP. Тело — сырые байты pkt-line или файла.
final class GitHttpResponse {
  const GitHttpResponse({
    required this.statusCode,
    required this.body,
    this.reasonPhrase = '',
  });

  final int statusCode;
  final List<int> body;
  final String reasonPhrase;
}

/// GET и POST для dumb и smart HTTP. Реализация подменяется в тестах,
/// чтобы не открывать сокет.
abstract interface class GitHttp {
  /// Выполняет запрос. Код «нет ресурса» не исключение: его разбирает репозиторий.
  Future<GitHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    List<int>? body,
  });
}

/// Боевой транспорт на `package:http`. На web это fetch, без `dart:io`.
///
/// Заголовки авторизации сюда приходят уже собранными и никуда не пишутся.
final class PackageGitHttp implements GitHttp {
  PackageGitHttp({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// Предел одного запроса. Оболочка обрывает команду своим таймаутом,
  /// этот предел не даёт запросу висеть дольше.
  final Duration timeout;

  @override
  Future<GitHttpResponse> send({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    request.headers.putIfAbsent('User-Agent', () => 'git/virtual-host');
    if (body != null) {
      request.bodyBytes = body;
    }
    final streamed = await _client.send(request).timeout(timeout);
    final bytes = await streamed.stream.toBytes().timeout(timeout);
    return GitHttpResponse(
      statusCode: streamed.statusCode,
      reasonPhrase: streamed.reasonPhrase ?? '',
      body: bytes,
    );
  }
}

/// Коды, которые скопированный репозиторий сравнивает с ответом.
abstract final class HttpStatus {
  static const ok = 200;
  static const unauthorized = 401;
  static const forbidden = 403;
  static const notFound = 404;
}

/// Текст тела ответа для сообщения об ошибке. Неполный UTF-8 не роняет транспорт.
String gitHttpBodyText(List<int> body) =>
    utf8.decode(body, allowMalformed: true);

/// Байты без лишней копии, если тело уже [Uint8List].
Uint8List gitHttpBytes(List<int> body) =>
    body is Uint8List ? body : Uint8List.fromList(body);
