import 'package:pw_client/pw_client.dart';

/// Платформенная заглушка для не-web сборок.
///
/// Сессия живёт в памяти процесса: после перезапуска приложения выдаётся
/// новая. Это ожидаемое поведение desktop и mobile.
final class PlatformClientSessionStore implements ClientSessionStore {
  final Map<String, String> _values = {};

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String value) => _values[key] = value;

  @override
  void delete(String key) => _values.remove(key);
}
