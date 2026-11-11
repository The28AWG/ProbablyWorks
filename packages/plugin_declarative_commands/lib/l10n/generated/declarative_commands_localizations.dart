import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'declarative_commands_localizations_en.dart';
import 'declarative_commands_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of DeclarativeCommandsLocalizations
/// returned by `DeclarativeCommandsLocalizations.of(context)`.
///
/// Applications need to include `DeclarativeCommandsLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/declarative_commands_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: DeclarativeCommandsLocalizations.localizationsDelegates,
///   supportedLocales: DeclarativeCommandsLocalizations.supportedLocales,
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
/// be consistent with the languages listed in the DeclarativeCommandsLocalizations.supportedLocales
/// property.
abstract class DeclarativeCommandsLocalizations {
  DeclarativeCommandsLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static DeclarativeCommandsLocalizations of(BuildContext context) {
    return Localizations.of<DeclarativeCommandsLocalizations>(
      context,
      DeclarativeCommandsLocalizations,
    )!;
  }

  static const LocalizationsDelegate<DeclarativeCommandsLocalizations>
  delegate = _DeclarativeCommandsLocalizationsDelegate();

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
  /// **'Declarative commands'**
  String get pluginTitle;

  /// Plugin description in the plugin list.
  ///
  /// In en, this message translates to:
  /// **'Turn fixed commands into tools the model can call.'**
  String get pluginDescription;

  /// Heading of the declarative commands settings screen.
  ///
  /// In en, this message translates to:
  /// **'Commands'**
  String get settingsTitle;

  /// Hint above the command list.
  ///
  /// In en, this message translates to:
  /// **'Each command becomes a tool. The model can call it, but cannot change the executable or fixed arguments.'**
  String get settingsHint;

  /// Button that opens the command editor.
  ///
  /// In en, this message translates to:
  /// **'Add command'**
  String get addCommand;

  /// Empty state title.
  ///
  /// In en, this message translates to:
  /// **'No commands'**
  String get emptyTitle;

  /// Empty state message.
  ///
  /// In en, this message translates to:
  /// **'Add a command to make it available to the model.'**
  String get emptyMessage;

  /// Title of the command editor when editing.
  ///
  /// In en, this message translates to:
  /// **'Edit command'**
  String get editCommand;

  /// Title of the command editor when adding.
  ///
  /// In en, this message translates to:
  /// **'New command'**
  String get newCommand;

  /// Command title field.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get name;

  /// Command description field.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get description;

  /// Executable field.
  ///
  /// In en, this message translates to:
  /// **'Executable'**
  String get executable;

  /// Fixed arguments field.
  ///
  /// In en, this message translates to:
  /// **'Arguments'**
  String get arguments;

  /// Fixed arguments hint.
  ///
  /// In en, this message translates to:
  /// **'One argument per line'**
  String get argumentsHint;

  /// Command timeout field.
  ///
  /// In en, this message translates to:
  /// **'Timeout, seconds'**
  String get timeout;

  /// Validation: empty command name.
  ///
  /// In en, this message translates to:
  /// **'Enter a name.'**
  String get invalidName;

  /// Validation: empty executable.
  ///
  /// In en, this message translates to:
  /// **'Enter an executable.'**
  String get invalidExecutable;

  /// Validation: invalid timeout.
  ///
  /// In en, this message translates to:
  /// **'Enter a positive timeout.'**
  String get invalidTimeout;

  /// Delete confirmation title.
  ///
  /// In en, this message translates to:
  /// **'Delete command'**
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

  /// Number of commands.
  ///
  /// In en, this message translates to:
  /// **'{count} commands'**
  String commandCount(int count);
}

class _DeclarativeCommandsLocalizationsDelegate
    extends LocalizationsDelegate<DeclarativeCommandsLocalizations> {
  const _DeclarativeCommandsLocalizationsDelegate();

  @override
  Future<DeclarativeCommandsLocalizations> load(Locale locale) {
    return SynchronousFuture<DeclarativeCommandsLocalizations>(
      lookupDeclarativeCommandsLocalizations(locale),
    );
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_DeclarativeCommandsLocalizationsDelegate old) => false;
}

DeclarativeCommandsLocalizations lookupDeclarativeCommandsLocalizations(
  Locale locale,
) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return DeclarativeCommandsLocalizationsEn();
    case 'ru':
      return DeclarativeCommandsLocalizationsRu();
  }

  throw FlutterError(
    'DeclarativeCommandsLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
