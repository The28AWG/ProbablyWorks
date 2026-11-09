import 'dart:async';
import 'dart:typed_data';

import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/turn/host_write_backup_path.dart';
import 'package:probably_works/agent/turn/shell_fs_mutation.dart';
import 'package:probably_works/agent/turn/turn_changeset.dart';
import 'package:probably_works/agent/turn/turn_changeset_logic.dart';
import 'package:probably_works/agent/turn/turn_changeset_store.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/shell_quote.dart';
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
    final backupName = turnChangesetBackupNameFor(path);
    final prior = cs.files[path];
    if (fileExisted && prior?.backupName == null) {
      await _store.writeBackupText(chatId, turnId, backupName, beforeText);
    }
    cs = turnChangesetRecordBeforeWrite(
      changeset: cs,
      path: path,
      fileExisted: fileExisted,
      backupName: backupName,
    );
    final saved = await _store.save(cs);
    _emit(saved);
    return saved;
  }

  /// Путь бэкапа на стороне Host для [WriteFileOp]; для local создаёт `staging/`.
  Future<String> prepareHostWriteBackupPath({
    required HostKind hostKind,
    required String chatId,
    required String turnId,
    required String targetPath,
    required String toolRunId,
  }) async {
    final appStaging = _store.stagingBackupPath(chatId, turnId, toolRunId);
    if (hostKind == HostKind.local) {
      await _store.ensureStagingDir(chatId, turnId);
    }
    return hostWriteBackupPath(
      hostKind: hostKind,
      targetPath: targetPath,
      runId: toolRunId,
      appStagingPath: appStaging,
    );
  }

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
    cs = turnChangesetMarkShellMutation(changeset: cs, toolRunId: toolRunId);
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
    required HostKind hostKind,
    String? cwd,
  }) async {
    if (changeset.rolledBack) {
      throw StateError('turn already rolled back');
    }
    final actions = turnChangesetRollbackPlan(changeset);
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
            hostKind: hostKind,
            chatId: changeset.chatId,
            turnId: changeset.turnId,
            path: path,
            bytes: bytes,
            cwd: cwd,
          );
      }
    }
    final saved = turnChangesetMarkRolledBack(changeset);
    final stored = await _store.save(saved);
    _emit(stored);
    return stored;
  }

  Future<void> _removeFile(
    HostRuntime runtime,
    String path, {
    String? cwd,
  }) async {
    final adapter = ShellAdapter(runtime.os);
    final command = switch (runtime.os) {
      HostOs.windows => adapter.powershell(
        'Remove-Item -LiteralPath ${psQuote(path)} -Force -ErrorAction SilentlyContinue',
      ),
      _ => 'rm -f -- ${adapter.quotePath(path)}',
    };
    final run = await captureRun(runtime, command, cwd: cwd);
    if (!run.ok && run.exitCode != 1) {
      throw StateError('failed to remove $path: ${run.stderr}');
    }
  }

  Future<void> _restoreFile(
    HostRuntime runtime, {
    required HostKind hostKind,
    required String chatId,
    required String turnId,
    required String path,
    required Uint8List bytes,
    String? cwd,
  }) async {
    final mtime = await _mtimeOrNull(runtime, path, cwd: cwd);
    final stagingId = _uuid.v4();
    final backupPath = await prepareHostWriteBackupPath(
      hostKind: hostKind,
      chatId: chatId,
      turnId: turnId,
      targetPath: path,
      toolRunId: stagingId,
    );
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
