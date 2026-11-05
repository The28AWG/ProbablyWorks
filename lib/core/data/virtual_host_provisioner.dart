import 'package:injectable/injectable.dart';
import 'package:probably_works/core/data/virtual_fs_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';
import 'package:probably_works/host/virtual/virtual_host_profile.dart';
import 'package:probably_works/host/virtual/virtual_host_seeder.dart';

/// Связывает виртуальные Host с их файловыми системами в базе: отдаёт VFS по id хоста и заполняет её.
///
/// Узел ФС ссылается на хост внешним ключом, поэтому заполнять ФС можно только после сохранения записи
/// хоста. Заполнение идемпотентно, поэтому вызывается при каждом сохранении виртуального Host.
@lazySingleton
class VirtualHostProvisioner {
  VirtualHostProvisioner(this._db);

  final AppDatabase _db;

  /// Файловая система хоста. Каждый вызов создаёт новый объект, но состояние живёт в базе.
  VirtualFs fsOf(String hostId) => VirtualFs(VirtualFsRepository(_db, hostId));

  /// Создаёт стартовое содержимое ФС для [host]. Вызывать только после записи хоста в базу.
  Future<void> provision(Host host) =>
      seedVirtualHost(fsOf(host.id), virtualProfileFor(host));
}
