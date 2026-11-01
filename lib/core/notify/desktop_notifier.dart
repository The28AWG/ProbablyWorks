import 'dart:io';

import 'package:injectable/injectable.dart';
import 'package:logging/logging.dart';

/// Системное уведомление. На Linux — `notify-send` (libnotify не нужен как зависимость Flutter).
/// Если утилиты нет, уведомление пропускается, а не падает.
@lazySingleton
class DesktopNotifier {
  final _log = Logger('DesktopNotifier');

  Future<void> notify({required String title, required String body}) async {
    if (!Platform.isLinux) return;
    try {
      final result = await Process.run('notify-send', [
        '--app-name=ProbablyWorks',
        title,
        body,
      ]);
      if (result.exitCode != 0) {
        _log.fine('notify-send exited with ${result.exitCode}');
      }
    } on ProcessException {
      _log.fine('notify-send is not installed; notification skipped');
    }
  }
}
