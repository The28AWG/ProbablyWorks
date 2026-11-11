import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'declarative_http_localizations_en.dart';
import 'declarative_http_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of DeclarativeHttpLocalizations
/// returned by `DeclarativeHttpLocalizations.of(context)`.
///
/// Applications need to include `DeclarativeHttpLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/declarative_http_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: DeclarativeHttpLocalizations.localizationsDelegates,
///   supportedLocales: DeclarativeHttpLocalizations.supportedLocales,
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
/// be consistent with the languages listed in the DeclarativeHttpLocalizations.supportedLocales
/// property.
abstract class DeclarativeHttpLocalizations {
  DeclarativeHttpLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static DeclarativeHttpLocalizations of(BuildContext context) {
    return Localizations.of<DeclarativeHttpLocalizations>(
      context,
      DeclarativeHttpLocalizations,
    )!;
  }

  static const LocalizationsDelegate<DeclarativeHttpLocalizations> delegate =
      _DeclarativeHttpLocalizationsDelegate();

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
  /// **'Declarative HTTP'**
  String get pluginTitle;

  /// Plugin description in the plugin list.
  ///
  /// In en, this message translates to:
  /// **'Turn HTTP requests into tools the model can call.'**
  String get pluginDescription;

  /// Heading of the HTTP tools settings screen.
  ///
  /// In en, this message translates to:
  /// **'HTTP tools'**
  String get settingsTitle;

  /// Hint above the HTTP tool list.
  ///
  /// In en, this message translates to:
  /// **'Tools call fixed HTTP endpoints. URL, headers and body may use argument placeholders.'**
  String get settingsHint;

  /// Button that opens the HTTP tool editor.
  ///
  /// In en, this message translates to:
  /// **'Add HTTP tool'**
  String get addTool;

  /// Empty state title.
  ///
  /// In en, this message translates to:
  /// **'No HTTP tools'**
  String get emptyTitle;

  /// Empty state message.
  ///
  /// In en, this message translates to:
  /// **'Add an HTTP tool to make it available to the model.'**
  String get emptyMessage;

  /// Title of the HTTP tool editor when adding.
  ///
  /// In en, this message translates to:
  /// **'New HTTP tool'**
  String get newTool;

  /// Title of the HTTP tool editor when editing.
  ///
  /// In en, this message translates to:
  /// **'Edit HTTP tool'**
  String get editTool;

  /// Tool name field.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get name;

  /// Tool description field.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get description;

  /// HTTP method field.
  ///
  /// In en, this message translates to:
  /// **'Method'**
  String get method;

  /// HTTP URL field.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get url;

  /// HTTP headers field.
  ///
  /// In en, this message translates to:
  /// **'Headers'**
  String get headers;

  /// HTTP headers hint.
  ///
  /// In en, this message translates to:
  /// **'KEY=VALUE, one per line'**
  String get headersHint;

  /// HTTP body field.
  ///
  /// In en, this message translates to:
  /// **'Body'**
  String get body;

  /// HTTP body hint.
  ///
  /// In en, this message translates to:
  /// **'JSON or text; leave empty for no body'**
  String get bodyHint;

  /// Tool arguments JSON schema field.
  ///
  /// In en, this message translates to:
  /// **'Arguments schema'**
  String get inputSchema;

  /// Tool arguments schema hint.
  ///
  /// In en, this message translates to:
  /// **'JSON Schema object'**
  String get inputSchemaHint;

  /// Response processing format.
  ///
  /// In en, this message translates to:
  /// **'Response'**
  String get responseFormat;

  /// Response format: raw text.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get responseText;

  /// Response format: parse JSON.
  ///
  /// In en, this message translates to:
  /// **'JSON'**
  String get responseJson;

  /// Response format: parse HTML.
  ///
  /// In en, this message translates to:
  /// **'HTML'**
  String get responseHtml;

  /// JSONPath selection field.
  ///
  /// In en, this message translates to:
  /// **'JSONPath'**
  String get jsonPath;

  /// JSONPath hint.
  ///
  /// In en, this message translates to:
  /// **'Optional, for example \$.items[*].name'**
  String get jsonPathHint;

  /// HTML CSS selector field.
  ///
  /// In en, this message translates to:
  /// **'CSS selector'**
  String get htmlSelector;

  /// HTML selector hint.
  ///
  /// In en, this message translates to:
  /// **'Optional, for example article .title'**
  String get htmlSelectorHint;

  /// HTTP timeout field.
  ///
  /// In en, this message translates to:
  /// **'Timeout, seconds'**
  String get timeout;

  /// Maximum response size field.
  ///
  /// In en, this message translates to:
  /// **'Max response characters'**
  String get maxResponseChars;

  /// Validation: empty name.
  ///
  /// In en, this message translates to:
  /// **'Enter a name.'**
  String get invalidName;

  /// Validation: invalid URL.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid http(s) URL.'**
  String get invalidUrl;

  /// Validation: unsupported HTTP method.
  ///
  /// In en, this message translates to:
  /// **'Use GET, POST, PUT, PATCH or DELETE.'**
  String get invalidMethod;

  /// Validation: invalid body JSON.
  ///
  /// In en, this message translates to:
  /// **'Body must be valid JSON or text.'**
  String get invalidBody;

  /// Validation: invalid arguments schema.
  ///
  /// In en, this message translates to:
  /// **'Arguments schema must be a JSON object.'**
  String get invalidSchema;

  /// Validation: invalid timeout.
  ///
  /// In en, this message translates to:
  /// **'Enter a positive timeout.'**
  String get invalidTimeout;

  /// Validation: invalid response size limit.
  ///
  /// In en, this message translates to:
  /// **'Enter a positive limit.'**
  String get invalidMaxChars;

  /// Delete confirmation title.
  ///
  /// In en, this message translates to:
  /// **'Delete HTTP tool'**
  String get deleteTitle;

  /// Delete confirmation message.
  ///
  /// In en, this message translates to:
  /// **'Delete “{name}”?'**
  String deleteConfirm(String name);

  /// Delete action.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// Edit action.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// Cancel action.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Save action.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// Number of HTTP tools.
  ///
  /// In en, this message translates to:
  /// **'{count} tools'**
  String toolCount(int count);
}

class _DeclarativeHttpLocalizationsDelegate
    extends LocalizationsDelegate<DeclarativeHttpLocalizations> {
  const _DeclarativeHttpLocalizationsDelegate();

  @override
  Future<DeclarativeHttpLocalizations> load(Locale locale) {
    return SynchronousFuture<DeclarativeHttpLocalizations>(
      lookupDeclarativeHttpLocalizations(locale),
    );
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_DeclarativeHttpLocalizationsDelegate old) => false;
}

DeclarativeHttpLocalizations lookupDeclarativeHttpLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return DeclarativeHttpLocalizationsEn();
    case 'ru':
      return DeclarativeHttpLocalizationsRu();
  }

  throw FlutterError(
    'DeclarativeHttpLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
