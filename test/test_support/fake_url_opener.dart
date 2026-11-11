import 'package:pw_agent/core/platform/external_url_opener.dart';

/// Не открывает браузер: тесты MCP не должны зависеть от окружения.
// ignore: avoid-top-level-members-in-tests, нужен нескольким тестам
class FakeUrlOpener implements ExternalUrlOpener {
  final opened = <Uri>[];

  @override
  Future<void> open(Uri url) async => opened.add(url);
}
