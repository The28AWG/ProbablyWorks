/// Настройки плагина «Веб».
///
/// Модель общая для ядра и экрана настроек. В JSON не попадают секреты: ключ
/// поискового провайдера хранится в `SecretStore` под отдельным именем.
library;

/// Поисковые провайдеры, которые поддерживает плагин.
enum WebSearchProvider { brave, tavily, searxng }

/// Настройки поиска.
final class WebSearchConfig {
  const WebSearchConfig({
    this.provider = WebSearchProvider.brave,
    this.endpoint = '',
    this.maxResults = 5,
    this.safeSearch = true,
    this.language = '',
  });

  factory WebSearchConfig.fromJson(Map<String, Object?> json) {
    final provider =
        WebSearchProvider.values
            .where((value) => value.name == json['provider'])
            .firstOrNull ??
        WebSearchProvider.brave;
    return WebSearchConfig(
      provider: provider,
      endpoint: _string(json['endpoint']),
      maxResults: _int(json['maxResults'], 5).clamp(1, 10),
      safeSearch: json['safeSearch'] != false,
      language: _string(json['language']),
    );
  }

  final WebSearchProvider provider;
  final String endpoint;
  final int maxResults;
  final bool safeSearch;
  final String language;

  /// Провайдер, которому нужен ключ API.
  bool get needsKey => provider != WebSearchProvider.searxng;

  /// Адрес по умолчанию, если пользователь не задал свой.
  String get effectiveEndpoint {
    final value = endpoint.trim();
    if (value.isNotEmpty) return value;
    return defaultEndpoint(provider);
  }

  static String defaultEndpoint(WebSearchProvider provider) =>
      switch (provider) {
        WebSearchProvider.brave =>
          'https://api.search.brave.com/res/v1/web/search',
        WebSearchProvider.tavily => 'https://api.tavily.com/search',
        WebSearchProvider.searxng => '',
      };

  Map<String, Object?> toJson() => {
    'provider': provider.name,
    'endpoint': endpoint,
    'maxResults': maxResults,
    'safeSearch': safeSearch,
    'language': language,
  };

  WebSearchConfig copyWith({
    WebSearchProvider? provider,
    String? endpoint,
    int? maxResults,
    bool? safeSearch,
    String? language,
  }) => WebSearchConfig(
    provider: provider ?? this.provider,
    endpoint: endpoint ?? this.endpoint,
    maxResults: maxResults ?? this.maxResults,
    safeSearch: safeSearch ?? this.safeSearch,
    language: language ?? this.language,
  );
}

/// Настройки загрузки и чтения страниц.
final class WebFetchConfig {
  const WebFetchConfig({
    this.maxBytes = 2097152,
    this.maxChars = 12000,
    this.timeoutSeconds = 20,
    this.userAgent = 'ProbablyWorks/1.0 (web plugin)',
    this.respectRobots = true,
    this.cacheTtlMinutes = 15,
  });

  factory WebFetchConfig.fromJson(Map<String, Object?> json) => WebFetchConfig(
    maxBytes: _int(json['maxBytes'], 2097152).clamp(65536, 8388608),
    maxChars: _int(json['maxChars'], 12000).clamp(1000, 30000),
    timeoutSeconds: _int(json['timeoutSeconds'], 20).clamp(1, 60),
    userAgent: _string(json['userAgent']).isEmpty
        ? 'ProbablyWorks/1.0 (web plugin)'
        : _string(json['userAgent']),
    respectRobots: json['respectRobots'] != false,
    cacheTtlMinutes: _int(json['cacheTtlMinutes'], 15).clamp(0, 1440),
  );

  final int maxBytes;
  final int maxChars;
  final int timeoutSeconds;
  final String userAgent;
  final bool respectRobots;
  final int cacheTtlMinutes;

  Duration get timeout => Duration(seconds: timeoutSeconds);
  Duration get cacheTtl => Duration(minutes: cacheTtlMinutes);

  Map<String, Object?> toJson() => {
    'maxBytes': maxBytes,
    'maxChars': maxChars,
    'timeoutSeconds': timeoutSeconds,
    'userAgent': userAgent,
    'respectRobots': respectRobots,
    'cacheTtlMinutes': cacheTtlMinutes,
  };

  WebFetchConfig copyWith({
    int? maxBytes,
    int? maxChars,
    int? timeoutSeconds,
    String? userAgent,
    bool? respectRobots,
    int? cacheTtlMinutes,
  }) => WebFetchConfig(
    maxBytes: maxBytes ?? this.maxBytes,
    maxChars: maxChars ?? this.maxChars,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    userAgent: userAgent ?? this.userAgent,
    respectRobots: respectRobots ?? this.respectRobots,
    cacheTtlMinutes: cacheTtlMinutes ?? this.cacheTtlMinutes,
  );
}

/// Разрешённые и запрещённые домены.
final class WebDomainPolicy {
  const WebDomainPolicy({this.allow = const [], this.deny = const []});

  factory WebDomainPolicy.fromJson(Map<String, Object?> json) =>
      WebDomainPolicy(
        allow: _domains(json['allow']),
        deny: _domains(json['deny']),
      );

  final List<String> allow;
  final List<String> deny;

  /// Запрет сильнее разрешения. Пустой allow означает «все домены».
  bool allows(String host) {
    final normalized = normalizeHost(host);
    if (normalized.isEmpty) return false;
    if (deny.any((domain) => _matches(normalized, domain))) return false;
    if (allow.isEmpty) return true;
    return allow.any((domain) => _matches(normalized, domain));
  }

  Map<String, Object?> toJson() => {'allow': allow, 'deny': deny};

  static String normalizeHost(String host) =>
      host.trim().toLowerCase().replaceFirst(RegExp(r'^\.'), '');

  static bool _matches(String host, String domain) {
    final normalized = normalizeHost(domain);
    if (normalized.isEmpty) return false;
    return host == normalized || host.endsWith('.$normalized');
  }

  static List<String> _domains(Object? raw) => raw is List
      ? {
          for (final value in raw)
            if (value is String && normalizeHost(value).isNotEmpty)
              normalizeHost(value),
        }.toList()
      : const [];
}

/// Полная конфигурация плагина.
final class WebConfig {
  const WebConfig({
    this.search = const WebSearchConfig(),
    this.fetch = const WebFetchConfig(),
    this.domains = const WebDomainPolicy(),
    this.renderer = 'none',
  });

  factory WebConfig.fromJson(Map<String, Object?> json) {
    final search = json['search'];
    final fetch = json['fetch'];
    final domains = json['domains'];
    return WebConfig(
      search: WebSearchConfig.fromJson(
        search is Map ? Map<String, Object?>.from(search) : const {},
      ),
      fetch: WebFetchConfig.fromJson(
        fetch is Map ? Map<String, Object?>.from(fetch) : const {},
      ),
      domains: WebDomainPolicy.fromJson(
        domains is Map ? Map<String, Object?>.from(domains) : const {},
      ),
      renderer: _string(json['renderer']).isEmpty
          ? 'none'
          : _string(json['renderer']),
    );
  }

  final WebSearchConfig search;
  final WebFetchConfig fetch;
  final WebDomainPolicy domains;

  /// Зарезервировано под будущий браузерный рендер. Сейчас всегда `none`.
  final String renderer;

  Map<String, Object?> toJson() => {
    'version': 1,
    'search': search.toJson(),
    'fetch': fetch.toJson(),
    'domains': domains.toJson(),
    'renderer': renderer,
  };

  WebConfig copyWith({
    WebSearchConfig? search,
    WebFetchConfig? fetch,
    WebDomainPolicy? domains,
    String? renderer,
  }) => WebConfig(
    search: search ?? this.search,
    fetch: fetch ?? this.fetch,
    domains: domains ?? this.domains,
    renderer: renderer ?? this.renderer,
  );
}

String _string(Object? value) => value is String ? value.trim() : '';

int _int(Object? value, int fallback) =>
    value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? fallback;
