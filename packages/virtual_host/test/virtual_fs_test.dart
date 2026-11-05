import 'package:test/test.dart';
import 'package:virtual_host/src/in_memory_vfs_store.dart';

// ignore: always_use_package_imports, сценарии общие с тестом базы и лежат в test/, а не в lib
import 'vfs_suite.dart';

void main() {
  group('InMemoryVfsStore', () => runVfsSuite(() async => InMemoryVfsStore()));
}
