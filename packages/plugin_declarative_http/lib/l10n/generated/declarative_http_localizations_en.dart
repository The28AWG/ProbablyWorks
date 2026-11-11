// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'declarative_http_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class DeclarativeHttpLocalizationsEn extends DeclarativeHttpLocalizations {
  DeclarativeHttpLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get pluginTitle => 'Declarative HTTP';

  @override
  String get pluginDescription =>
      'Turn HTTP requests into tools the model can call.';

  @override
  String get settingsTitle => 'HTTP tools';

  @override
  String get settingsHint =>
      'Tools call fixed HTTP endpoints. URL, headers and body may use argument placeholders.';

  @override
  String get addTool => 'Add HTTP tool';

  @override
  String get emptyTitle => 'No HTTP tools';

  @override
  String get emptyMessage =>
      'Add an HTTP tool to make it available to the model.';

  @override
  String get newTool => 'New HTTP tool';

  @override
  String get editTool => 'Edit HTTP tool';

  @override
  String get name => 'Name';

  @override
  String get description => 'Description';

  @override
  String get method => 'Method';

  @override
  String get url => 'URL';

  @override
  String get headers => 'Headers';

  @override
  String get headersHint => 'KEY=VALUE, one per line';

  @override
  String get body => 'Body';

  @override
  String get bodyHint => 'JSON or text; leave empty for no body';

  @override
  String get inputSchema => 'Arguments schema';

  @override
  String get inputSchemaHint => 'JSON Schema object';

  @override
  String get responseFormat => 'Response';

  @override
  String get responseText => 'Text';

  @override
  String get responseJson => 'JSON';

  @override
  String get responseHtml => 'HTML';

  @override
  String get jsonPath => 'JSONPath';

  @override
  String get jsonPathHint => 'Optional, for example \$.items[*].name';

  @override
  String get htmlSelector => 'CSS selector';

  @override
  String get htmlSelectorHint => 'Optional, for example article .title';

  @override
  String get timeout => 'Timeout, seconds';

  @override
  String get maxResponseChars => 'Max response characters';

  @override
  String get invalidName => 'Enter a name.';

  @override
  String get invalidUrl => 'Enter a valid http(s) URL.';

  @override
  String get invalidMethod => 'Use GET, POST, PUT, PATCH or DELETE.';

  @override
  String get invalidBody => 'Body must be valid JSON or text.';

  @override
  String get invalidSchema => 'Arguments schema must be a JSON object.';

  @override
  String get invalidTimeout => 'Enter a positive timeout.';

  @override
  String get invalidMaxChars => 'Enter a positive limit.';

  @override
  String get deleteTitle => 'Delete HTTP tool';

  @override
  String deleteConfirm(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get delete => 'Delete';

  @override
  String get edit => 'Edit';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String toolCount(int count) {
    return '$count tools';
  }
}
