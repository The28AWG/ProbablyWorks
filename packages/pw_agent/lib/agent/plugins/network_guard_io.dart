/// Проверка адреса назначения HTTP-запроса на IO-платформах.
///
/// Задача — не дать веб-плагину и его редиректам уйти в loopback, link-local
/// или приватную сеть. Это не полноценная защита от DNS rebinding: клиент
/// резолвит имя повторно при соединении. Ограничение честно описано в
/// `docs/agent/WEB_PLUGIN.md`.
library;

import 'dart:io';

/// Проверяет хост и все адреса, которые вернул DNS.
Future<void> networkGuardCheck(
  Uri uri, {
  required bool allowLoopback,
  required bool allowPrivateNetwork,
}) async {
  final host = uri.host;
  if (host.isEmpty) throw StateError('URL has no host');
  if (_isLoopbackName(host) && !allowLoopback) {
    throw StateError('loopback network is not allowed');
  }
  if (_isPrivateName(host) && !allowPrivateNetwork) {
    throw StateError('private network is not allowed');
  }

  final addresses = await InternetAddress.lookup(host);
  if (addresses.isEmpty) throw StateError('cannot resolve host: $host');
  for (final address in addresses) {
    if (_isLoopback(address) && allowLoopback) continue;
    if (_isPrivate(address) && allowPrivateNetwork) continue;
    if (_isLoopback(address) || _isPrivate(address)) {
      throw StateError('private network is not allowed: ${address.address}');
    }
  }
}

bool _isLoopbackName(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized.endsWith('.localhost') ||
      normalized == '127.0.0.1' ||
      normalized == '::1' ||
      normalized == '[::1]';
}

bool _isPrivateName(String host) {
  final normalized = host.toLowerCase();
  return normalized.endsWith('.local') ||
      normalized.endsWith('.internal') ||
      normalized.endsWith('.lan') ||
      normalized == 'metadata.google.internal';
}

bool _isLoopback(InternetAddress address) =>
    address.isLoopback ||
    address.address == '0.0.0.0' ||
    address.address == '::';

bool _isPrivate(InternetAddress address) {
  if (address.type == InternetAddressType.IPv4) {
    final bytes = address.rawAddress;
    if (bytes.length != 4) return true;
    final a = bytes.first;
    final b = bytes[1];
    return a == 0 ||
        a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254) ||
        (a == 100 && b >= 64 && b <= 127) ||
        (a == 192 && b == 0 && bytes[2] == 0) ||
        (a == 198 && (b == 18 || b == 19)) ||
        a >= 224;
  }
  if (address.type == InternetAddressType.IPv6) {
    final bytes = address.rawAddress;
    if (bytes.length < 16) return true;
    final first = bytes.first;
    final second = bytes[1];
    // fc00::/7 — unique local, fe80::/10 — link-local, ff00::/8 — multicast.
    if ((first & 0xfe) == 0xfc) return true;
    if (first == 0xfe && (second & 0xc0) == 0x80) return true;
    if (first == 0xff) return true;
    // ::ffff:a.b.c.d — IPv4-mapped адрес.
    if (bytes.take(10).every((value) => value == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff) {
      return _isPrivate(InternetAddress.fromRawAddress(bytes.sublist(12)));
    }
    return false;
  }
  return true;
}
