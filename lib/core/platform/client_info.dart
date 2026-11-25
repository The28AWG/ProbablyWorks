import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Сведения о клиенте, которые уходят в HTTP-заголовках удалённого API.
///
/// Версия и сборка нужны, чтобы по журналу доступа понять, какой клиент
/// сломался. Значения ограничены ASCII и длиной, чтобы не портить заголовки.
final class ClientInfo {
  const ClientInfo({
    required this.packageName,
    required this.version,
    required this.buildNumber,
    this.clientId,
  });

  factory ClientInfo.fromPackageInfo(PackageInfo info, {String? clientId}) =>
      ClientInfo(
        packageName: _safe(info.packageName, fallback: fallbackPackageName),
        version: _safe(info.version, fallback: fallbackVersion),
        buildNumber: _safe(info.buildNumber, fallback: fallbackBuildNumber),
        clientId: _safeId(clientId),
      );

  /// Запасной вариант, если платформа не отдала PackageInfo.
  const ClientInfo.fallback({this.clientId})
    : packageName = fallbackPackageName,
      version = fallbackVersion,
      buildNumber = fallbackBuildNumber;

  /// Название приложения в заголовках и интерфейсе.
  ///
  /// Это постоянная часть продукта. `PackageInfo.appName` здесь не
  /// используется: на web и части desktop-платформ он содержит имя пакета
  /// (`probably_works`), а не человекочитаемое название.
  static const appName = 'ProbablyWorks';

  /// Значения, если платформа не отдала PackageInfo.
  static const fallbackPackageName = 'probably_works';
  static const fallbackVersion = '0.0.0';
  static const fallbackBuildNumber = '0';

  final String packageName;
  final String version;
  final String buildNumber;

  /// Стабильный id установки. null — хранилище недоступно или это старый
  /// клиент без сохранённого id; тогда сервер группирует по отпечатку.
  final String? clientId;

  Map<String, String> get headers => {
    'x-client-app': appName,
    'x-client-package': packageName,
    'x-client-version': version,
    'x-client-build': buildNumber,
    'x-client-platform': kIsWeb
        ? 'web'
        : defaultTargetPlatform.name.toLowerCase(),
    'x-client-id': ?clientId,
  };

  static String _safe(String value, {required String fallback}) {
    final cleaned = value.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();
    if (cleaned.isEmpty) return fallback;
    return cleaned.length <= 120
        ? cleaned
        : String.fromCharCodes(cleaned.codeUnits.take(120));
  }

  /// Приводит id к тому же безопасному виду, что проверяет сервер.
  static String? _safeId(String? value) {
    if (value == null) return null;
    final cleaned = value.replaceAll(RegExp('[^A-Za-z0-9._-]'), '').trim();
    if (cleaned.isEmpty) return null;
    return cleaned.length <= 64
        ? cleaned
        : String.fromCharCodes(cleaned.codeUnits.take(64));
  }
}
