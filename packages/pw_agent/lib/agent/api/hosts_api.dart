import 'package:pw_agent/core/domain/host.dart';

/// Управление хостами: список, сохранение с секретами, удаление и проверка.
///
/// Локальная реализация пишет в БД и secure storage напрямую, удалённая —
/// через API сервера. Секреты не попадают в таблицу хостов.
abstract interface class HostsApi {
  Future<List<Host>> hosts();
  Stream<List<Host>> watchHosts();

  Future<void> saveHost(Host host, {String? secret, String? privateKeyPem});
  Future<void> deleteHost(String id);
  Future<void> testHost(Host host);
}
