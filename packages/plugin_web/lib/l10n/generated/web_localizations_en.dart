// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'web_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class WebLocalizationsEn extends WebLocalizations {
  WebLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get pluginTitle => 'Web: search and page data';

  @override
  String get pluginDescription =>
      'Search the web, read pages as text and collect structured records with CSS selectors.';

  @override
  String get searchSection => 'Search';

  @override
  String get searchSectionHint =>
      'Search is available only after a provider and API key are configured. Page reading works without search.';

  @override
  String get provider => 'Provider';

  @override
  String get providerBrave => 'Brave';

  @override
  String get providerBraveHint => 'Independent index, needs an API key.';

  @override
  String get providerTavily => 'Tavily';

  @override
  String get providerTavilyHint => 'Search API for agents, needs an API key.';

  @override
  String get providerSearxng => 'SearXNG';

  @override
  String get providerSearxngHint =>
      'Self-hosted instance with JSON output, no key.';

  @override
  String get endpoint => 'Endpoint';

  @override
  String get endpointHint => 'Leave empty for the provider default.';

  @override
  String get apiKey => 'API key';

  @override
  String get apiKeyHint =>
      'The key is stored in the OS secret store and is never shown again.';

  @override
  String get apiKeySaved => 'A key is saved';

  @override
  String get apiKeyRemove => 'Remove key';

  @override
  String get apiKeyRemoved => 'API key removed';

  @override
  String get maxResults => 'Results by default';

  @override
  String get safeSearch => 'Safe search';

  @override
  String get language => 'Search language';

  @override
  String get languageHint => 'Optional language code, for example en or ru.';

  @override
  String get pagesSection => 'Pages';

  @override
  String get pagesSectionHint =>
      'Limits protect the model context and the network. A page is stored as cleaned text, not as raw HTML.';

  @override
  String get maxChars => 'Characters per reply';

  @override
  String get maxBytes => 'Maximum page size, bytes';

  @override
  String get timeoutSeconds => 'Timeout, seconds';

  @override
  String get userAgent => 'User-Agent';

  @override
  String get userAgentHint =>
      'A honest User-Agent helps sites identify the client.';

  @override
  String get respectRobots => 'Respect robots.txt';

  @override
  String get cacheTtl => 'Page cache, minutes';

  @override
  String get cacheNote =>
      'Pages live in memory with an LRU limit and expire by TTL. Restarting the app clears the cache.';

  @override
  String get domainsSection => 'Domains';

  @override
  String get domainsSectionHint =>
      'One domain per line. A denied domain always wins. An empty allow list means all domains.';

  @override
  String get allowedDomains => 'Allowed domains';

  @override
  String get allowedDomainsHint => 'example.com\ndocs.example.com';

  @override
  String get deniedDomains => 'Denied domains';

  @override
  String get deniedDomainsHint => 'ads.example.com';

  @override
  String get save => 'Save';

  @override
  String get saved => 'Web plugin settings saved';

  @override
  String saveFailed(String error) {
    return 'Could not save settings: $error';
  }

  @override
  String get loading => 'Loading settings…';

  @override
  String get errorTitle => 'Could not load settings';

  @override
  String get invalidNumber => 'Enter a number within the allowed range.';

  @override
  String get invalidEndpoint => 'Enter an http:// or https:// URL.';

  @override
  String get invalidEndpointRequired => 'A SearXNG endpoint is required.';

  @override
  String get searchNotConfigured =>
      'Search is not configured. Page reading is still available.';
}
