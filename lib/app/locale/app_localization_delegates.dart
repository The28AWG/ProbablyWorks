import 'package:flutter_localizations/flutter_localizations.dart'
    as flutter_l10n;
import 'package:material_ui/material_ui.dart';
import 'package:plugin_declarative_commands/l10n/generated/declarative_commands_localizations.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Делегаты для [MaterialApp] из `material_ui`.
///
/// - [GlobalMaterialLocalizations.delegates] — виджеты `material_ui` (Stepper, Dialog, …).
/// - [flutter_l10n.GlobalMaterialLocalizations] — виджеты из `package:flutter/material`
///   (например [SelectionArea] в `markdown_widget`).
const appLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  AppLocalizations.delegate,
  DeclarativeCommandsLocalizations.delegate,
  ...GlobalMaterialLocalizations.delegates,
  flutter_l10n.GlobalMaterialLocalizations.delegate,
];
