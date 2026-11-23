import 'package:pw_client/pw_client.dart';

/// На нативных платформах вкладок нет, поэтому id всегда свободен.
final class PlatformClientSessionChannel implements ClientSessionChannel {
  const PlatformClientSessionChannel();

  /// На платформе без вкладок id всегда свободен.
  @override
  Future<bool> isActive(String id) async => false;

  /// Закрывать нечего: вкладок нет.
  @override
  // ignore: no-empty-block, на платформе без вкладок нет ресурсов
  void close() {}
}
