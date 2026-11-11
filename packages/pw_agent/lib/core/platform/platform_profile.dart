import 'dart:io';

/// Возможности платформы, нужные ядру агента.
///
/// Не использует Flutter: демон и клиент видят одинаковые правила.
final class PlatformProfile {
  const PlatformProfile();

  static const current = PlatformProfile();

  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// На iOS песочница не порождает shell, поэтому локального Host нет.
  bool get hasLocalHost => !Platform.isIOS;

  /// На мобильных ключ SSH хранится как PEM в secure storage, а не по пути.
  bool get canOpenExternalKeys => !isMobile;
}
