import 'package:background_downloader/background_downloader.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Уведомления платформенного загрузчика моделей.
///
/// Android показывает progress bar и кнопки паузы/отмены; iOS — одно
/// уведомление о ходе загрузки и завершении (без progress bar: Apple его не
/// поддерживает). Тексты берутся из ARB и пересоздаются при смене языка.
abstract final class DownloadNotifications {
  const DownloadNotifications._();

  /// Настраивает глобальные уведомления загрузчика.
  static void configure(AppLocalizations l10n) {
    FileDownloader().configureNotification(
      running: TaskNotification(
        l10n.localModelsNotificationTitle,
        '{displayName}',
      ),
      complete: TaskNotification(
        l10n.localModelsNotificationDone,
        '{displayName}',
      ),
      error: TaskNotification(
        l10n.localModelsNotificationError,
        '{displayName}',
      ),
      progressBar: true,
    );
  }
}
