import 'package:flutter/material.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Подпись локального Host: компьютер на десктопе, телефон на Android.
String localHostTitle(AppLocalizations l10n, {AppPlatform? platform}) =>
    (platform ?? AppPlatform.current).isMobile
    ? l10n.hostLocalNameMobile
    : l10n.hostLocalName;

/// Иконка локального Host в списках и меню.
IconData localHostIcon({AppPlatform? platform}) =>
    (platform ?? AppPlatform.current).isMobile
    ? Icons.smartphone_outlined
    : Icons.computer_outlined;
