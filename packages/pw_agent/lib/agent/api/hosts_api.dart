import 'package:pw_agent/core/domain/host.dart';

/// Управление хостами: список, сохранение с секретами, удаление и проверка.
///
/// Локальная реализация пишет в БД и secure storage напрямую, удалённая —
/// через API сервера. Секреты не попадают в таблицу хостов.
abstract interface class HostsApi {
  Future<List<Host>> hosts();
  Stream<List<Host>> watchHosts();

  /// Сохраняет Host и его секреты. `environment` — карта переменных хоста;
  /// null означает «не менять», пустая карта удаляет переменные.
  Future<void> saveHost(
    Host host, {
    String? secret,
    String? privateKeyPem,
    Map<String, String>? environment,
  });
  Future<void> deleteHost(String id);
  Future<void> testHost(Host host);
}
