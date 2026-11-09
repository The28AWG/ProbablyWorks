/// Чистая логика учёта и планирования отката изменений файлов в ходе.
library;

import 'package:characters/characters.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/interaction/edit_file_changes_request.dart';
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

/// Id пользовательских сообщений, для которых ещё можно откатить файлы при rewind.
///
/// [afterOnly] — только сообщения строго после [anchorSeq] (удаление хвоста).
List<String> turnIdsWithPendingFileChanges({
  required List<ChatMessage> messages,
  required Map<String, TurnChangeset> allTurns,
  required int anchorSeq,
  required bool afterOnly,
}) {
  final ids = <String>[];
  for (final message in messages) {
    if (message.role != MessageRole.user) continue;
    final inRange = afterOnly
        ? message.seq > anchorSeq
        : message.seq >= anchorSeq;
    if (!inRange) continue;
    final cs = allTurns[message.id];
    if (cs == null || cs.rolledBack || cs.keptOnEdit) continue;
    if (cs.files.isEmpty && !cs.nonRecoverable) continue;
    ids.add(message.id);
  }
  return ids;
}

/// Сортирует id ответов агента от нового к старому (для цепочки отката).
List<String> turnIdsNewestFirst({
  required List<ChatMessage> messages,
  required List<String> turnIds,
}) {
  final seqById = {
    for (final message in messages)
      if (message.role == MessageRole.user) message.id: message.seq,
  };
  return List<String>.of(turnIds)..sort((a, b) {
    final seqA = seqById[a] ?? 0;
    final seqB = seqById[b] ?? 0;
    return seqB.compareTo(seqA);
  });
}

/// Сводка путей для диалога: при конфликте побеждает более поздний ответ агента.
List<EditFileChangesEntry> aggregateEditFileChanges({
  required Map<String, TurnChangeset> allTurns,
  required List<String> turnIdsOldestFirst,
}) {
  final byPath = <String, TurnFileKind>{};
  for (final turnId in turnIdsOldestFirst) {
    final cs = allTurns[turnId];
    if (cs == null) continue;
    for (final change in cs.files.values) {
      byPath[change.path] = change.kind;
    }
  }
  return [
    for (final entry in byPath.entries)
      EditFileChangesEntry(path: entry.key, kind: entry.value),
  ]..sort((a, b) => a.path.compareTo(b.path));
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

/// Сбой отката одного пути или ответа агента.
final class TurnRollbackFailure {
  const TurnRollbackFailure({required this.path, required this.message});

  final String path;
  final String message;
}

/// Итог цепочки отката (сначала более новые ответы агента).
final class TurnRollbackChainResult {
  const TurnRollbackChainResult({this.failures = const []});

  final List<TurnRollbackFailure> failures;

  bool get ok => failures.isEmpty;

  String describe() =>
      [for (final failure in failures) '${failure.path}: ${failure.message}']
          .join('; ');
}
