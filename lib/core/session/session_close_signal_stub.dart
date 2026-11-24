// ignore_for_file: avoid-unused-parameters, вне web сигнал закрытия не нужен
/// На платформах без вкладок отдельный keepalive-сигнал не нужен: сессию
/// закрывает `dispose` обычным запросом.
Future<void> sendSessionClosing({
  required Uri baseUri,
  required String token,
  required String sessionId,
  required Map<String, String> headers,
}) => Future<void>.value();
