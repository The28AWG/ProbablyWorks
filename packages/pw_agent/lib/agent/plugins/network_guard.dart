/// Проверка сетевого адреса перед HTTP-запросом плагина.
///
/// Реализация зависит от платформы: на IO-платформах адрес резолвится через
/// DNS, в web проверка недоступна. Импорт выбирается условно, чтобы
/// `plugin_tool_source.dart` не тянул `dart:io` в web-сборку.
library;

import 'package:pw_agent/agent/plugins/network_guard_stub.dart'
    if (dart.library.io) 'package:pw_agent/agent/plugins/network_guard_io.dart';

/// Проверяет, что [uri] не ведёт в loopback или приватную сеть, если это
/// запрещено настройками вызова. Бросает [StateError] при нарушении.
Future<void> ensureNetworkAllowed(
  Uri uri, {
  required bool allowLoopback,
  required bool allowPrivateNetwork,
}) => networkGuardCheck(
  uri,
  allowLoopback: allowLoopback,
  allowPrivateNetwork: allowPrivateNetwork,
);
