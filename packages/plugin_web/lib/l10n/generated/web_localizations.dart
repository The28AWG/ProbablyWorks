import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'web_localizations_en.dart';
import 'web_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of WebLocalizations
/// returned by `WebLocalizations.of(context)`.
///
/// Applications need to include `WebLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/web_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: WebLocalizations.localizationsDelegates,
///   supportedLocales: WebLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the WebLocalizations.supportedLocales
/// property.
abstract class WebLocalizations {
  WebLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static WebLocalizations of(BuildContext context) {
    return Localizations.of<WebLocalizations>(context, WebLocalizations)!;
  }

  static const LocalizationsDelegate<WebLocalizations> delegate =
      _WebLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// Plugin title in the plugin list.
  ///
  /// In en, this message translates to:
  /// **'Web: search and page data'**
  String get pluginTitle;

  /// Plugin description in the plugin list.
  ///
  /// In en, this message translates to:
  /// **'Search the web, read pages as text and collect structured records with CSS selectors.'**
  String get pluginDescription;

  /// Search settings section title.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get searchSection;

  /// Hint above search settings.
  ///
  /// In en, this message translates to:
  /// **'Search is available only after a provider and API key are configured. Page reading works without search.'**
  String get searchSectionHint;

  /// Search provider field label.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get provider;

  /// Brave provider option.
  ///
  /// In en, this message translates to:
  /// **'Brave'**
  String get providerBrave;

  /// Brave provider hint.
  ///
  /// In en, this message translates to:
  /// **'Independent index, needs an API key.'**
  String get providerBraveHint;

  /// Tavily provider option.
  ///
  /// In en, this message translates to:
  /// **'Tavily'**
  String get providerTavily;

  /// Tavily provider hint.
  ///
  /// In en, this message translates to:
  /// **'Search API for agents, needs an API key.'**
  String get providerTavilyHint;

  /// SearXNG provider option.
  ///
  /// In en, this message translates to:
  /// **'SearXNG'**
  String get providerSearxng;

  /// SearXNG provider hint.
  ///
  /// In en, this message translates to:
  /// **'Self-hosted instance with JSON output, no key.'**
  String get providerSearxngHint;

  /// Search endpoint field label.
  ///
  /// In en, this message translates to:
  /// **'Endpoint'**
  String get endpoint;

  /// Search endpoint hint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty for the provider default.'**
  String get endpointHint;

  /// API key field label.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get apiKey;

  /// API key field hint.
  ///
  /// In en, this message translates to:
  /// **'The key is stored in the OS secret store and is never shown again.'**
  String get apiKeyHint;

  /// Shown when a search API key exists.
  ///
  /// In en, this message translates to:
  /// **'A key is saved'**
  String get apiKeySaved;

  /// Button that deletes the search API key.
  ///
  /// In en, this message translates to:
  /// **'Remove key'**
  String get apiKeyRemove;

  /// Snackbar after removing the key.
  ///
  /// In en, this message translates to:
  /// **'API key removed'**
  String get apiKeyRemoved;

  /// Default number of search results.
  ///
  /// In en, this message translates to:
  /// **'Results by default'**
  String get maxResults;

  /// Safe search switch label.
  ///
  /// In en, this message translates to:
  /// **'Safe search'**
  String get safeSearch;

  /// Search language field label.
  ///
  /// In en, this message translates to:
  /// **'Search language'**
  String get language;

  /// Search language hint.
  ///
  /// In en, this message translates to:
  /// **'Optional language code, for example en or ru.'**
  String get languageHint;

  /// Page fetching settings section title.
  ///
  /// In en, this message translates to:
  /// **'Pages'**
  String get pagesSection;

  /// Hint above page settings.
  ///
  /// In en, this message translates to:
  /// **'Limits protect the model context and the network. A page is stored as cleaned text, not as raw HTML.'**
  String get pagesSectionHint;

  /// Maximum characters returned by web_open.
  ///
  /// In en, this message translates to:
  /// **'Characters per reply'**
  String get maxChars;

  /// Maximum downloaded page size.
  ///
  /// In en, this message translates to:
  /// **'Maximum page size, bytes'**
  String get maxBytes;

  /// Request timeout field.
  ///
  /// In en, this message translates to:
  /// **'Timeout, seconds'**
  String get timeoutSeconds;

  /// HTTP User-Agent field.
  ///
  /// In en, this message translates to:
  /// **'User-Agent'**
  String get userAgent;

  /// User-Agent hint.
  ///
  /// In en, this message translates to:
  /// **'A honest User-Agent helps sites identify the client.'**
  String get userAgentHint;

  /// robots.txt switch label.
  ///
  /// In en, this message translates to:
  /// **'Respect robots.txt'**
  String get respectRobots;

  /// Page cache TTL field.
  ///
  /// In en, this message translates to:
  /// **'Page cache, minutes'**
  String get cacheTtl;

  /// Note about the in-memory page cache.
  ///
  /// In en, this message translates to:
  /// **'Pages live in memory with an LRU limit and expire by TTL. Restarting the app clears the cache.'**
  String get cacheNote;

  /// Domain policy section title.
  ///
  /// In en, this message translates to:
  /// **'Domains'**
  String get domainsSection;

  /// Hint above domain lists.
  ///
  /// In en, this message translates to:
  /// **'One domain per line. A denied domain always wins. An empty allow list means all domains.'**
  String get domainsSectionHint;

  /// Allowed domains field label.
  ///
  /// In en, this message translates to:
  /// **'Allowed domains'**
  String get allowedDomains;

  /// Allowed domains hint.
  ///
  /// In en, this message translates to:
  /// **'example.com\ndocs.example.com'**
  String get allowedDomainsHint;

  /// Denied domains field label.
  ///
  /// In en, this message translates to:
  /// **'Denied domains'**
  String get deniedDomains;

  /// Denied domains hint.
  ///
  /// In en, this message translates to:
  /// **'ads.example.com'**
  String get deniedDomainsHint;

  /// Save button.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// Snackbar after saving settings.
  ///
  /// In en, this message translates to:
  /// **'Web plugin settings saved'**
  String get saved;

  /// Snackbar when settings cannot be saved.
  ///
  /// In en, this message translates to:
  /// **'Could not save settings: {error}'**
  String saveFailed(String error);

  /// Loading state.
  ///
  /// In en, this message translates to:
  /// **'Loading settings…'**
  String get loading;

  /// Settings loading error title.
  ///
  /// In en, this message translates to:
  /// **'Could not load settings'**
  String get errorTitle;

  /// Validation error for numeric fields.
  ///
  /// In en, this message translates to:
  /// **'Enter a number within the allowed range.'**
  String get invalidNumber;

  /// Validation error for the endpoint.
  ///
  /// In en, this message translates to:
  /// **'Enter an http:// or https:// URL.'**
  String get invalidEndpoint;

  /// Validation error when SearXNG has no endpoint.
  ///
  /// In en, this message translates to:
  /// **'A SearXNG endpoint is required.'**
  String get invalidEndpointRequired;

  /// Status shown when search has no provider or key.
  ///
  /// In en, this message translates to:
  /// **'Search is not configured. Page reading is still available.'**
  String get searchNotConfigured;
}

class _WebLocalizationsDelegate
    extends LocalizationsDelegate<WebLocalizations> {
  const _WebLocalizationsDelegate();

  @override
  Future<WebLocalizations> load(Locale locale) {
    return SynchronousFuture<WebLocalizations>(lookupWebLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_WebLocalizationsDelegate old) => false;
}

WebLocalizations lookupWebLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return WebLocalizationsEn();
    case 'ru':
      return WebLocalizationsRu();
  }

  throw FlutterError(
    'WebLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
