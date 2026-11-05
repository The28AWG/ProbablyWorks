import 'package:injectable/injectable.dart';
import 'package:probably_works/core/data/virtual_fs_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/virtual/in_memory_vfs_store.dart';
import 'package:probably_works/host/virtual/os_snapshot.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';
import 'package:probably_works/host/virtual/virtual_host_profile.dart';
import 'package:probably_works/host/virtual/virtual_host_seeder.dart';

/// Связывает виртуальные Host с их файловыми системами в базе: отдаёт VFS по id хоста и заполняет её.
///
/// Узел ФС ссылается на хост внешним ключом, поэтому заполнять ФС можно только после сохранения записи
/// хоста. Заполнение идемпотентно, поэтому вызывается при каждом сохранении виртуального Host.
/// Память `/tmp` живёт в карте провизионера: каждый [fsOf] создаёт новый [VirtualFs], но для одного
/// host id отдаёт тот же объект. Карта исчезает вместе с процессом, отдельного хука на выгрузку нет.
@lazySingleton
class VirtualHostProvisioner {
  VirtualHostProvisioner(this._db);

  final AppDatabase _db;
  final Map<String, InMemoryVfsStore> _scratch = {};

  /// Файловая система хоста. Постоянные файлы — в базе, `/tmp` — в памяти процесса.
  /// [snapshot] задаёт вызывающий, у которого есть профиль и реестр команд.
  VirtualFs fsOf(String hostId, {OsSnapshot? snapshot}) => VirtualFs(
    VirtualFsRepository(_db, hostId),
    snapshot: snapshot,
    temporary: _scratch.putIfAbsent(hostId, InMemoryVfsStore.new),
  );

  /// Создаёт стартовое содержимое ФС для [host]. Вызывать только после записи хоста в базу.
  Future<void> provision(Host host) =>
      seedVirtualHost(fsOf(host.id), virtualProfileFor(host));
}
