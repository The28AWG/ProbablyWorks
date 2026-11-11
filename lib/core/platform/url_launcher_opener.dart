import 'package:injectable/injectable.dart';
import 'package:pw_agent/core/platform/external_url_opener.dart';
import 'package:url_launcher/url_launcher.dart';

/// Открывает OAuth-страницы в браузере через `url_launcher`.
@LazySingleton(as: ExternalUrlOpener)
class UrlLauncherOpener implements ExternalUrlOpener {
  const UrlLauncherOpener();

  @override
  Future<void> open(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw StateError('cannot open authorization URL');
    }
  }
}
