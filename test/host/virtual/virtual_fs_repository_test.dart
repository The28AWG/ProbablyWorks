import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/virtual_fs_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';

// ignore: always_use_package_imports, те же сценарии, что у памяти: правила в VirtualFs, база обязана совпасть
import '../../../packages/virtual_host/test/vfs_suite.dart';

/// База проходит те же сценарии, что память пакета: правила живут в VirtualFs, не в хранилище.
void main() {
  group('VirtualFsRepository', () {
    late AppDatabase db;

    setUp(() async {
      db = openInMemoryDatabase();
      await HostRepository(
        db,
        MemorySecretStore(),
      ).ensureLocalHost(DateTime(2026, 11, 1));
    });

    tearDown(() => db.close());

    runVfsSuite(
      () async => VirtualFsRepository(db, HostRepository.localHostId),
    );
  });
}
