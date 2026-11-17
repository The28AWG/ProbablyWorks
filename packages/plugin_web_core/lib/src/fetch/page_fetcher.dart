import 'dart:convert';
import 'dart:typed_data';

import 'package:plugin_api/plugin_api.dart';
import 'package:plugin_web_core/src/fetch/fetched_page.dart';
import 'package:plugin_web_core/src/web_config.dart';
import 'package:plugin_web_core/src/web_error.dart';

/// Загружает страницы через [PluginHost] и проверяет редиректы.
///
/// Плагин не ходит в сеть сам: хост проверяет HTTPS, адрес назначения и
/// подставляет секреты. Здесь остаются политика доменов, robots.txt, лимиты и
/// кодировка.
final class PageFetcher {
  PageFetcher({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _robots = <String, _RobotsEntry>{};

  static const _maxRedirects = 5;

  /// Скачивает страницу и возвращает декодированное тело.
  Future<FetchedPage> fetch({
    required String url,
    required WebConfig config,
    required PluginHost host,
  }) async {
    var current = _checkedUri(url);
    _checkDomain(current, config);
    if (config.fetch.respectRobots && !await _allowed(current, config, host)) {
      throw WebToolException(
        'robots_disallowed',
        'robots.txt disallows ${current.path}',
        hint: 'ask the user before bypassing robots.txt',
      );
    }
    for (var redirect = 0; redirect <= _maxRedirects; redirect++) {
      final response = await host.httpRequest(
        method: 'GET',
        url: current.toString(),
        headers: {
          'accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,'
              'text/plain;q=0.8,application/json;q=0.7',
          'user-agent': config.fetch.userAgent,
        },
        timeout: config.fetch.timeout,
        followRedirects: false,
        allowLoopback: false,
        allowPrivateNetwork: false,
        maxBytes: config.fetch.maxBytes,
      );
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          throw const WebToolException(
            'bad_redirect',
            'redirect response has no Location header',
          );
        }
        final next = current.resolve(location);
        final checked = _checkedUri(next.toString());
        _checkDomain(checked, config);
        if (config.fetch.respectRobots &&
            !await _allowed(checked, config, host)) {
          throw WebToolException(
            'robots_disallowed',
            'robots.txt disallows ${checked.path}',
            hint: 'ask the user before bypassing robots.txt',
          );
        }
        current = checked;
        continue;
      }
      if (response.isError ||
          response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw WebToolException(
          _statusCode(response.statusCode),
          'page request failed with HTTP ${response.statusCode}',
          hint: _statusHint(response.statusCode),
        );
      }
      if (response.truncated) {
        throw WebToolException(
          'response_too_large',
          'page is larger than ${config.fetch.maxBytes} bytes',
          hint: 'the page was not stored because it was truncated',
        );
      }
      final contentType = response.contentType ?? '';
      if (!_supported(contentType)) {
        throw WebToolException(
          'unsupported_content_type',
          'unsupported content type: ${contentType.isEmpty ? 'unknown' : contentType}',
          hint: 'the plugin reads text, HTML, JSON and XML pages',
        );
      }
      final bytes = response.bodyBytes;
      final body = bytes == null ? response.body : _decode(bytes, contentType);
      return FetchedPage(
        requestedUrl: url,
        finalUrl: response.finalUrl ?? current.toString(),
        statusCode: response.statusCode,
        contentType: contentType,
        body: body,
        fetchedAt: _now().toUtc(),
        etag: response.headers['etag'] ?? '',
        lastModified: response.headers['last-modified'] ?? '',
      );
    }
    throw const WebToolException(
      'too_many_redirects',
      'page redirected too many times',
      hint: 'open the final URL directly',
    );
  }

  Uri _checkedUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw const WebToolException(
        'bad_url',
        'invalid URL',
        hint: 'use https://',
      );
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw WebToolException(
        'bad_url',
        'unsupported URL scheme: ${uri.scheme}',
        hint: 'only http and https are allowed',
      );
    }
    return uri;
  }

  void _checkDomain(Uri uri, WebConfig config) {
    if (!config.domains.allows(uri.host)) {
      throw WebToolException(
        'domain_blocked',
        'domain is blocked by the plugin policy: ${uri.host}',
        hint: 'change the domain lists in the web plugin settings',
      );
    }
  }

  Future<bool> _allowed(Uri uri, WebConfig config, PluginHost host) async {
    final origin = '${uri.scheme}://${uri.host}:${uri.port}';
    final cached = _robots[origin];
    if (cached != null && cached.expiresAt.isAfter(_now())) {
      return cached.rules.allows(uri.path, config.fetch.userAgent);
    }
    final rules = await _loadRobots(uri, config, host);
    _robots[origin] = _RobotsEntry(
      rules: rules,
      expiresAt: _now().add(const Duration(hours: 1)),
    );
    return rules.allows(uri.path, config.fetch.userAgent);
  }

  Future<_RobotsRules> _loadRobots(
    Uri uri,
    WebConfig config,
    PluginHost host,
  ) async {
    final robots = uri.replace(path: '/robots.txt', query: '', fragment: '');
    try {
      final response = await host.httpRequest(
        method: 'GET',
        url: robots.toString(),
        headers: {'user-agent': config.fetch.userAgent},
        timeout: config.fetch.timeout,
        followRedirects: false,
        allowLoopback: false,
        allowPrivateNetwork: false,
        maxBytes: 64 * 1024,
      );
      if (response.isError ||
          response.statusCode < 200 ||
          response.statusCode >= 300) {
        return _RobotsRules.empty;
      }
      return _RobotsRules.parse(response.body);
    } on Object {
      // Сеть или адрес недоступны: robots.txt не должен блокировать чтение
      // из-за собственной ошибки. Это стандартное поведение клиентов.
      return _RobotsRules.empty;
    }
  }

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  static bool _supported(String contentType) {
    final type = contentType.toLowerCase();
    return type.contains('text/html') ||
        type.contains('application/xhtml+xml') ||
        type.contains('text/plain') ||
        type.contains('text/markdown') ||
        type.contains('application/json') ||
        type.contains('+json') ||
        type.contains('application/xml') ||
        type.contains('text/xml') ||
        type.contains('+xml');
  }

  static String _statusCode(int status) => switch (status) {
    401 || 403 => 'access_denied',
    404 || 410 => 'not_found',
    429 => 'rate_limited',
    >= 500 => 'server_error',
    _ => 'http_status',
  };

  static String _statusHint(int status) => switch (status) {
    401 || 403 => 'the page may require authorization',
    404 || 410 => 'check the URL or use web_search to find another page',
    429 => 'wait before trying the same host again',
    >= 500 => 'the site is currently unavailable',
    _ => 'HTTP $status',
  };

  static String _decode(Uint8List bytes, String contentType) {
    final header = _charsetOf(contentType);
    final meta = header == null ? _metaCharset(bytes) : null;
    final name = header ?? meta;
    final encoding = name == null ? utf8 : (Encoding.getByName(name) ?? utf8);
    if (encoding == utf8) return utf8.decode(bytes, allowMalformed: true);
    try {
      return encoding.decode(bytes);
    } on Object {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static String? _charsetOf(String contentType) {
    final match = RegExp(
      r'charset\s*=\s*"?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(contentType);
    return match?.group(1)?.trim();
  }

  static String? _metaCharset(Uint8List bytes) {
    final head = latin1.decode(
      bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes,
    );
    final match = RegExp(
      r'''<meta[^>]+charset\s*=\s*["']?([A-Za-z0-9_-]+)''',
      caseSensitive: false,
    ).firstMatch(head);
    return match?.group(1);
  }
}

final class _RobotsEntry {
  const _RobotsEntry({required this.rules, required this.expiresAt});

  final _RobotsRules rules;
  final DateTime expiresAt;
}

final class _RobotsRules {
  const _RobotsRules(this._rules);

  factory _RobotsRules.parse(String raw) {
    final rules = <String, List<_RobotsRule>>{};
    var agents = <String>[];
    var inRules = false;
    for (final line in raw.split('\n')) {
      final value = line.split('#').first.trim();
      if (value.isEmpty) continue;
      final separator = value.indexOf(':');
      if (separator <= 0) continue;
      // ignore: avoid-substring, robots.txt lines are ASCII and offsets are code units
      final key = value.substring(0, separator).trim().toLowerCase();
      // ignore: avoid-substring, robots.txt lines are ASCII and offsets are code units
      final field = value.substring(separator + 1).trim();
      if (key == 'user-agent') {
        if (inRules) {
          agents = [];
          inRules = false;
        }
        agents.add(field.toLowerCase());
      } else if (key == 'allow' || key == 'disallow') {
        inRules = true;
        if (field.isEmpty) continue;
        for (final agent in agents) {
          rules
              .putIfAbsent(agent, () => [])
              .add(_RobotsRule(path: field, allow: key == 'allow'));
        }
      }
    }
    return _RobotsRules(rules);
  }
  static const empty = _RobotsRules({});

  final Map<String, List<_RobotsRule>> _rules;

  bool allows(String path, String userAgent) {
    final group = _groupFor(userAgent);
    if (group.isEmpty) return true;
    _RobotsRule? best;
    for (final rule in group) {
      if (!path.startsWith(rule.path)) continue;
      if (best == null ||
          rule.path.length > best.path.length ||
          (rule.path.length == best.path.length && rule.allow)) {
        best = rule;
      }
    }
    return best?.allow ?? true;
  }

  List<_RobotsRule> _groupFor(String userAgent) {
    final agent = userAgent.toLowerCase();
    for (final entry in _rules.entries) {
      if (entry.key != '*' && agent.contains(entry.key)) return entry.value;
    }
    return _rules['*'] ?? const [];
  }
}

final class _RobotsRule {
  const _RobotsRule({required this.path, required this.allow});

  final String path;
  final bool allow;
}
