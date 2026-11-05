import 'package:flutter/material.dart';
import 'package:probably_works/core/domain/host.dart';
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

/// Название Host для интерфейса: локальный — переводом под платформу, остальные — своё имя.
String hostDisplayName(
  Host host,
  AppLocalizations l10n, {
  AppPlatform? platform,
}) => host.isLocal ? localHostTitle(l10n, platform: platform) : host.name;

/// Иконка Host: компьютер или телефон для локального, микросхема для виртуального, сервер для SSH.
IconData hostDisplayIcon(Host host, {AppPlatform? platform}) =>
    switch (host.kind) {
      HostKind.local => localHostIcon(platform: platform),
      HostKind.ssh => Icons.dns_outlined,
      HostKind.virtual => Icons.memory_outlined,
    };
