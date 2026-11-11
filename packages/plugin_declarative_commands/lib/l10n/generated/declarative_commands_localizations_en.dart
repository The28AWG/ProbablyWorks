// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'declarative_commands_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class DeclarativeCommandsLocalizationsEn
    extends DeclarativeCommandsLocalizations {
  DeclarativeCommandsLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get pluginTitle => 'Declarative commands';

  @override
  String get pluginDescription =>
      'Turn fixed commands into tools the model can call.';

  @override
  String get settingsTitle => 'Commands';

  @override
  String get settingsHint =>
      'Each command becomes a tool. The model can call it, but cannot change the executable or fixed arguments.';

  @override
  String get addCommand => 'Add command';

  @override
  String get emptyTitle => 'No commands';

  @override
  String get emptyMessage => 'Add a command to make it available to the model.';

  @override
  String get editCommand => 'Edit command';

  @override
  String get newCommand => 'New command';

  @override
  String get name => 'Name';

  @override
  String get description => 'Description';

  @override
  String get executable => 'Executable';

  @override
  String get arguments => 'Arguments';

  @override
  String get argumentsHint => 'One argument per line';

  @override
  String get timeout => 'Timeout, seconds';

  @override
  String get invalidName => 'Enter a name.';

  @override
  String get invalidExecutable => 'Enter an executable.';

  @override
  String get invalidTimeout => 'Enter a positive timeout.';

  @override
  String get deleteTitle => 'Delete command';

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
  String commandCount(int count) {
    return '$count commands';
  }
}
