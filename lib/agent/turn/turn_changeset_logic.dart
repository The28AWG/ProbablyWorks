/// Чистая логика учёта и планирования отката изменений файлов в ходе.
library;

import 'package:characters/characters.dart';
import 'package:probably_works/agent/turn/turn_changeset.dart';
import 'package:probably_works/agent/turn/turn_file_kind.dart';
import 'package:probably_works/core/util/char_substring.dart';

/// Имя файла снимка в `backups/` по пути на Host.
String turnChangesetBackupNameFor(String hostPath) {
  final safe = hostPath.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  final tail = safe.characters.length > 64 ? charSuffix(safe, 64) : safe;
  return '${hostPath.hashCode.abs().toRadixString(16)}_$tail.bin';
}

/// Перед записью через write_file/edit_file: фиксирует исходное состояние.
TurnChangeset turnChangesetRecordBeforeWrite({
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
TurnChangeset turnChangesetRecordDelete({
  required TurnChangeset changeset,
  required String path,
}) {
  final existing = changeset.files[path];
  if (existing?.kind == TurnFileKind.created) {
    final next = Map<String, TurnFileChange>.of(changeset.files)..remove(path);
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

TurnChangeset turnChangesetMarkShellMutation({
  required TurnChangeset changeset,
  required String toolRunId,
}) {
  if (changeset.shellMutationToolRunIds.contains(toolRunId)) {
    return changeset;
  }
  return changeset.copyWith(
    nonRecoverable: true,
    shellMutationToolRunIds: [...changeset.shellMutationToolRunIds, toolRunId],
    updatedAt: DateTime.now(),
  );
}

TurnChangeset turnChangesetMarkRolledBack(TurnChangeset changeset) =>
    changeset.copyWith(rolledBack: true, updatedAt: DateTime.now());

/// Действие отката для одного пути.
RollbackFileAction turnChangesetActionFor(TurnFileChange change) =>
    switch (change.kind) {
      TurnFileKind.created => RollbackRemove(change.path),
      TurnFileKind.modified || TurnFileKind.deleted => RollbackRestore(
        change.path,
        backupName: change.backupName!,
      ),
    };

List<RollbackFileAction> turnChangesetRollbackPlan(TurnChangeset changeset) => [
  for (final change in changeset.files.values) turnChangesetActionFor(change),
];

/// Путь, из‑за которого нельзя откатить более ранний ход: поздний ход трогал тот же файл.
///
/// Откатывайте сначала более новые ходы (больший [userSeqByMessageId]).
String? turnChangesetRollbackBlocked({
  required TurnChangeset changeset,
  required int turnUserSeq,
  required Map<String, TurnChangeset> allTurns,
  required Map<String, int> userSeqByMessageId,
}) {
  final paths = changeset.files.keys.toSet();
  for (final other in allTurns.values) {
    if (other.turnId == changeset.turnId || other.rolledBack) continue;
    final seq = userSeqByMessageId[other.turnId];
    if (seq == null || seq <= turnUserSeq) continue;
    for (final path in other.files.keys) {
      if (paths.contains(path)) return path;
    }
  }
  return null;
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
