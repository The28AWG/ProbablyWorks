import 'dart:async';
import 'dart:typed_data';

import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/turn/shell_fs_mutation.dart';
import 'package:probably_works/agent/turn/turn_changeset.dart';
import 'package:probably_works/agent/turn/turn_changeset_logic.dart';
import 'package:probably_works/agent/turn/turn_changeset_store.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/shell_adapter.dart';
import 'package:uuid/uuid.dart';

/// Учёт изменений файлов в ходе агента и откат на Host.
@lazySingleton
class TurnChangesetService {
  TurnChangesetService(this._store);

  static const _uuid = Uuid();

  final TurnChangesetStore _store;

  final _changes = StreamController<TurnChangeset>.broadcast();

  TurnChangesetStore get store => _store;

  Stream<TurnChangeset> get changes => _changes.stream;

  void _emit(TurnChangeset changeset) {
    if (!_changes.isClosed) _changes.add(changeset);
  }

  Future<TurnChangeset> _open(String chatId, String turnId) async {
    final existing = await _store.load(chatId, turnId);
    if (existing != null) return existing;
    return TurnChangeset(
      chatId: chatId,
      turnId: turnId,
      updatedAt: DateTime.now(),
    );
  }

  Future<TurnChangeset> recordBeforeWrite({
    required String chatId,
    required String turnId,
    required String path,
    required bool fileExisted,
    required String beforeText,
  }) async {
    var cs = await _open(chatId, turnId);
    final backupName = TurnChangesetLogic.backupNameFor(path);
    final prior = cs.files[path];
    if (fileExisted && prior?.backupName == null) {
      await _store.writeBackupText(chatId, turnId, backupName, beforeText);
    }
    cs = TurnChangesetLogic.recordBeforeWrite(
      changeset: cs,
      path: path,
      fileExisted: fileExisted,
      backupName: backupName,
    );
    final saved = await _store.save(cs);
    _emit(saved);
    return saved;
  }

  String writeStagingBackupPath(
    String chatId,
    String turnId,
    String toolRunId,
  ) => _store.stagingBackupPath(chatId, turnId, toolRunId);

  Future<TurnChangeset> recordShellMutation({
    required String chatId,
    required String turnId,
    required String toolRunId,
    required CommandClassifier classifier,
    required String command,
  }) async {
    if (!shellMayMutateFilesystem(classifier, command)) {
      return await _open(chatId, turnId);
    }
    var cs = await _open(chatId, turnId);
    cs = TurnChangesetLogic.markShellMutation(
      changeset: cs,
      toolRunId: toolRunId,
    );
    final saved = await _store.save(cs);
    _emit(saved);
    return saved;
  }

  Future<Map<String, TurnChangeset>> forChat(String chatId) =>
      _store.loadForChat(chatId);

  Future<TurnChangeset?> get(String chatId, String turnId) =>
      _store.load(chatId, turnId);

  /// Откатывает изменения хода на [runtime].
  Future<TurnChangeset> rollback({
    required TurnChangeset changeset,
    required HostRuntime runtime,
    String? cwd,
  }) async {
    if (changeset.rolledBack) {
      throw StateError('turn already rolled back');
    }
    final actions = TurnChangesetLogic.rollbackPlan(changeset);
    for (final action in actions) {
      switch (action) {
        case RollbackRemove(:final path):
          await _removeFile(runtime, path, cwd: cwd);
        case RollbackRestore(:final path, :final backupName):
          final bytes = await _store.readBackup(
            changeset.chatId,
            changeset.turnId,
            backupName,
          );
          if (bytes == null) {
            throw StateError('backup missing for $path');
          }
          await _restoreFile(
            runtime,
            changeset.chatId,
            changeset.turnId,
            path,
            bytes,
            cwd: cwd,
          );
      }
    }
    final saved = TurnChangesetLogic.markRolledBack(changeset);
    final stored = await _store.save(saved);
    _emit(stored);
    return stored;
  }

  Future<void> _removeFile(
    HostRuntime runtime,
    String path, {
    String? cwd,
  }) async {
    final quoted = quotePath(path);
    final run = await captureRun(runtime, 'rm -f -- $quoted', cwd: cwd);
    if (!run.ok && run.exitCode != 1) {
      throw StateError('failed to remove $path: ${run.stderr}');
    }
  }

  Future<void> _restoreFile(
    HostRuntime runtime,
    String chatId,
    String turnId,
    String path,
    Uint8List bytes, {
    String? cwd,
  }) async {
    final mtime = await _mtimeOrNull(runtime, path, cwd: cwd);
    final stagingId = _uuid.v4();
    final backupPath = _store.stagingBackupPath(chatId, turnId, stagingId);
    final run = await captureOp(
      runtime,
      WriteFileOp(path, backupPath: backupPath, expectedMtime: mtime),
      cwd: cwd,
      stdin: bytes,
    );
    if (!run.ok) {
      throw StateError('failed to restore $path: ${run.stderr}');
    }
  }

  Future<String?> _mtimeOrNull(
    HostRuntime runtime,
    String path, {
    String? cwd,
  }) async {
    final run = await captureOp(runtime, StatOp(path), cwd: cwd);
    if (!run.ok) return null;
    return StatResult.parse(run.stdout)?.mtime;
  }
}
