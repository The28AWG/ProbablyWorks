import 'package:probably_works/core/domain/host.dart';

/// Путь временного файла для `cp` в [WriteFileOp] на стороне Host.
///
/// Снимок для отката хода пишется в [TurnChangesetStore] из Dart. Здесь только
/// бэкап на время атомарной записи: каталог должен быть доступен процессу на
/// том же Host, где лежит целевой файл (для SSH — не каталог данных приложения).
String hostWriteBackupPath({
  required HostKind hostKind,
  required String targetPath,
  required String runId,
  required String appStagingPath,
}) => switch (hostKind) {
  HostKind.local => appStagingPath,
  HostKind.ssh => '/tmp/pw-stg-$runId',
  HostKind.virtual => '$targetPath.pw-stg-$runId',
};
