import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart';
import 'package:probably_works/core/domain/mcp_server.dart';
import 'package:probably_works/core/security/secret_store.dart';

/// OAuth-токены MCP-сервера в SecretStore.
String mcpOAuthTokensKey(String serverId) => 'mcp.$serverId.oauth.tokens';

/// OAuth authorization-code provider с локальным callback-сервером.
///
/// Сам обмен кода на токен делает `mcp_dart`; провайдер только хранит токены,
/// открывает браузер и принимает redirect на loopback-порт.
final class McpOAuthProvider implements OAuthAuthorizationCodeProvider {
  McpOAuthProvider({
    required this.server,
    required this.secrets,
    required this.openUrl,
  });

  final McpServerConfig server;
  final SecretStore secrets;
  final Future<void> Function(Uri) openUrl;

  HttpServer? _server;
  Completer<({String code, String state})>? _callback;

  @override
  String get clientId => server.oauth?.clientId ?? '';

  @override
  String? get clientSecret => null;

  @override
  Uri get redirectUri => Uri.parse(
    'http://127.0.0.1:${server.oauth?.redirectPort ?? 8765}/callback',
  );

  @override
  List<String> get scopes => server.oauth?.scopes ?? const [];

  @override
  Future<OAuthTokens?> tokens() async {
    final raw = await secrets.read(mcpOAuthTokensKey(server.id));
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final access = json['accessToken'];
      if (access is! String || access.isEmpty) return null;
      final refresh = json['refreshToken'];
      return OAuthTokens(
        accessToken: access,
        refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> saveTokens(OAuthTokens tokens) => secrets.write(
    mcpOAuthTokensKey(server.id),
    jsonEncode({
      'accessToken': tokens.accessToken,
      if (tokens.refreshToken != null) 'refreshToken': tokens.refreshToken,
    }),
  );

  @override
  Future<void> redirectToAuthorization() => Future<void>.value();

  @override
  Future<void> redirectToAuthorizationUrl(Uri authorizationUri) async {
    final callback = _callback ??= Completer();
    await _ensureServer();
    try {
      await openUrl(authorizationUri);
    } on Object catch (error) {
      if (!callback.isCompleted) callback.completeError(error);
      rethrow;
    }
  }

  /// Ждёт redirect с кодом. Вызывается после того, как транспорт попросил авторизацию.
  Future<({String code, String state})> waitForCallback({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final callback = _callback ??= Completer();
    try {
      return await callback.future.timeout(timeout);
    } finally {
      await _closeServer();
    }
  }

  Future<void> _ensureServer() async {
    if (_server != null) return;
    final serverOAuth = server.oauth;
    if (serverOAuth == null) {
      throw StateError('OAuth is not configured for ${server.name}');
    }
    final listener = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      serverOAuth.redirectPort,
    );
    _server = listener;
    listener.listen((request) async {
      if (request.uri.path != '/callback') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final params = request.uri.queryParameters;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><meta charset="utf-8">'
          '<title>ProbablyWorks</title>'
          '<p>Authorization complete. You can close this window.</p>',
        );
      await request.response.close();
      final error = params['error'];
      final code = params['code'];
      final state = params['state'];
      final callback = _callback ??= Completer();
      if (error != null && error.isNotEmpty) {
        if (!callback.isCompleted) {
          callback.completeError(StateError('OAuth error: $error'));
        }
      } else if (code != null && code.isNotEmpty && state != null) {
        if (!callback.isCompleted) {
          callback.complete((code: code, state: state));
        }
      } else if (!callback.isCompleted) {
        callback.completeError(
          const FormatException('incomplete OAuth callback'),
        );
      }
    });
  }

  Future<void> _closeServer() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  /// Закрывает callback-сервер.
  Future<void> close() => _closeServer();
}
