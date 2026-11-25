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
  ///
  /// [expectedRevision] — `revision` снимка, с которого открыта форма. При
  /// несовпадении реализация бросает `409 host_conflict` до записи. Без него
  /// (служебная запись, старый клиент) ревизия не проверяется и просто растёт.
  Future<void> saveHost(
    Host host, {
    String? secret,
    String? privateKeyPem,
    Map<String, String>? environment,
    int? expectedRevision,
  });
  Future<void> deleteHost(String id);
  Future<void> testHost(Host host);
}
