/// Заглушка сетевой проверки для платформ без `dart:io`.
///
/// В web плагины с доступом к сети не используются. Если такой вызов всё же
/// случится, лучше явно отказать, чем пропустить запрос без проверки адреса.
library;

/// Всегда отказывает: без `dart:io` нельзя проверить IP-адрес назначения.
Future<void> networkGuardCheck(
  Uri uri, {
  required bool allowLoopback,
  required bool allowPrivateNetwork,
}) async => throw StateError(
  'network guard is unavailable: $uri '
  '(loopback=$allowLoopback, private=$allowPrivateNetwork)',
);
