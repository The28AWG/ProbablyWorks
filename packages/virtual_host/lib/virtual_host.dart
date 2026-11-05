/// Ядро виртуального хоста: файловая система, ограниченная оболочка и апплеты.
///
/// Приложение само выбирает хранилище и переводит события оболочки в свой рантайм.
/// Сторонний апплет реализует [Applet] и проверяется через [ShellInterpreter]
/// на [InMemoryVfsStore].
library;

export 'src/in_memory_vfs_store.dart';
export 'src/os_snapshot.dart';
export 'src/posix_regex.dart';
export 'src/shell/applets/applet.dart';
export 'src/shell/applets/applet_args.dart';
export 'src/shell/applets/standard_applets.dart';
export 'src/shell/shell_interpreter.dart';
export 'src/shell/shell_io.dart';
export 'src/vfs_access.dart';
export 'src/vfs_listing.dart';
export 'src/vfs_path.dart';
export 'src/vfs_store.dart';
export 'src/virtual_fs.dart';
export 'src/virtual_host_seeder.dart';
export 'src/virtual_limits.dart';
export 'src/virtual_profile.dart';
