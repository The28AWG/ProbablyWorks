/// Чистая логика учёта и планирования отката изменений файлов в ходе.
library;

import 'package:probably_works/agent/turn/turn_changeset.dart';
import 'package:probably_works/agent/turn/turn_file_kind.dart';

/// Чистая логика учёта касаний файла и планирования отката (без I/O).
abstract final class TurnChangesetLogic {
  /// Имя файла снимка в `backups/` по пути на Host.
  static String backupNameFor(String hostPath) {
    final safe = hostPath.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final tail = safe.length > 64 ? safe.substring(safe.length - 64) : safe;
    return '${hostPath.hashCode.abs().toRadixString(16)}_$tail.bin';
  }

  /// Перед записью через write_file/edit_file: фиксирует исходное состояние.
  static TurnChangeset recordBeforeWrite({
    required TurnChangeset changeset,
    required String path,
    required bool fileExisted,
    required String backupName,
  }) {
    final existing = changeset.files[path];
    if (existing != null) {
      if (existing.kind == TurnFileKind.deleted) {
        return changeset.copyWith(
          files: {
            ...changeset.files,
            path: TurnFileChange(
              path: path,
              kind: fileExisted ? TurnFileKind.modified : TurnFileKind.created,
              backupName: fileExisted ? backupName : null,
            ),
          },
          updatedAt: DateTime.now(),
        );
      }
      return changeset;
    }
    final kind = fileExisted ? TurnFileKind.modified : TurnFileKind.created;
    return changeset.copyWith(
      files: {
        ...changeset.files,
        path: TurnFileChange(
          path: path,
          kind: kind,
          backupName: fileExisted ? backupName : null,
        ),
      },
      updatedAt: DateTime.now(),
    );
  }

  /// Явное удаление файла инструментами (не shell).
  static TurnChangeset recordDelete({
    required TurnChangeset changeset,
    required String path,
  }) {
    final existing = changeset.files[path];
    if (existing?.kind == TurnFileKind.created) {
      final next = Map<String, TurnFileChange>.from(changeset.files)
        ..remove(path);
      return changeset.copyWith(files: next, updatedAt: DateTime.now());
    }
    final backup = existing?.backupName;
    return changeset.copyWith(
      files: {
        ...changeset.files,
        path: TurnFileChange(
          path: path,
          kind: TurnFileKind.deleted,
          backupName: backup,
        ),
      },
      updatedAt: DateTime.now(),
    );
  }

  static TurnChangeset markShellMutation({
    required TurnChangeset changeset,
    required String toolRunId,
  }) {
    if (changeset.shellMutationToolRunIds.contains(toolRunId)) {
      return changeset;
    }
    return changeset.copyWith(
      nonRecoverable: true,
      shellMutationToolRunIds: [
        ...changeset.shellMutationToolRunIds,
        toolRunId,
      ],
      updatedAt: DateTime.now(),
    );
  }

  static TurnChangeset markRolledBack(TurnChangeset changeset) =>
      changeset.copyWith(rolledBack: true, updatedAt: DateTime.now());

  /// Действие отката для одного пути.
  static RollbackFileAction actionFor(TurnFileChange change) =>
      switch (change.kind) {
        TurnFileKind.created => RollbackRemove(change.path),
        TurnFileKind.modified || TurnFileKind.deleted => RollbackRestore(
          change.path,
          backupName: change.backupName!,
        ),
      };

  static List<RollbackFileAction> rollbackPlan(TurnChangeset changeset) => [
    for (final change in changeset.files.values) actionFor(change),
  ];
}

/// Одно файловое действие при откате хода.
sealed class RollbackFileAction {
  const RollbackFileAction();
}

final class RollbackRemove extends RollbackFileAction {
  const RollbackRemove(this.path);
  final String path;
}

final class RollbackRestore extends RollbackFileAction {
  const RollbackRestore(this.path, {required this.backupName});
  final String path;
  final String backupName;
}
