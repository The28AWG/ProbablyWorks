import 'dart:async';
import 'dart:io';

import 'package:pw_agent/core/platform/external_url_opener.dart';

/// Открывает OAuth-ссылки системной командой; если браузера нет, печатает URL.
final class ProcessUrlOpener implements ExternalUrlOpener {
  const ProcessUrlOpener();

  @override
  Future<void> open(Uri url) async {
    try {
      final command = switch (Platform.operatingSystem) {
        'linux' => ('xdg-open', [url.toString()]),
        'macos' => ('open', [url.toString()]),
        'windows' => ('cmd', ['/c', 'start', '', url.toString()]),
        _ => null,
      };
      if (command == null) {
        stdout.writeln('Open this URL to finish authorization: $url');
        return;
      }
      final process = await Process.start(command.$1, command.$2);
      unawaited(process.exitCode);
    } on Object {
      stdout.writeln('Open this URL to finish authorization: $url');
    }
  }
}
