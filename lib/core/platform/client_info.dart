import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// Сведения о клиенте, которые уходят в HTTP-заголовках удалённого API.
///
/// Версия и сборка нужны, чтобы по журналу доступа понять, какой клиент
/// сломался. Значения ограничены ASCII и длиной, чтобы не портить заголовки.
final class ClientInfo {
  const ClientInfo({
    required this.appName,
    required this.packageName,
    required this.version,
    required this.buildNumber,
  });

  factory ClientInfo.fromPackageInfo(PackageInfo info) => ClientInfo(
    appName: _safe(info.appName),
    packageName: _safe(info.packageName),
    version: _safe(info.version),
    buildNumber: _safe(info.buildNumber),
  );

  /// Запасной вариант, если платформа не отдала PackageInfo.
  const ClientInfo.fallback()
    : appName = 'ProbablyWorks',
      packageName = 'probably_works',
      version = '0.0.0',
      buildNumber = '0';

  final String appName;
  final String packageName;
  final String version;
  final String buildNumber;

  Map<String, String> get headers => {
    'x-client-app': appName,
    'x-client-package': packageName,
    'x-client-version': version,
    'x-client-build': buildNumber,
    'x-client-platform': Platform.operatingSystem,
  };

  static String _safe(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
    return cleaned.length <= 120
        ? cleaned
        : String.fromCharCodes(cleaned.codeUnits.take(120));
  }
}
