/// Заглушка для web: платформенного загрузчика и уведомлений там нет.
library;

import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Уведомления платформенного загрузчика моделей.
abstract final class DownloadNotifications {
  const DownloadNotifications._();

  /// На web уведомлений загрузчика нет.
  // ignore: no-empty-block, на web нет платформенного загрузчика моделей
  static void configure(AppLocalizations _) {}
}
