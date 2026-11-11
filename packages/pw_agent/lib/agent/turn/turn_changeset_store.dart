/// Файловое хранилище снимков хода агента (manifest и backups).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:pw_agent/agent/turn/turn_changeset.dart';
import 'package:pw_agent/core/security/file_permissions.dart';

/// Файлы снимков и manifest ходов агента.
///
/// Пути: `<root>/chats/<chatId>/turns/<turnId>/manifest.json`, `backups/*`,
/// `staging/*` (временные бэкапы для атомарной записи на Host).
class TurnChangesetStore {
  TurnChangesetStore(this.rootDir);

  final Directory rootDir;

  Directory turnDir(String chatId, String turnId) =>
      Directory(p.join(rootDir.path, 'chats', chatId, 'turns', turnId));

  Directory backupsDir(String chatId, String turnId) =>
      Directory(p.join(turnDir(chatId, turnId).path, 'backups'));

  Directory stagingDir(String chatId, String turnId) =>
      Directory(p.join(turnDir(chatId, turnId).path, 'staging'));

  File manifestFile(String chatId, String turnId) =>
      File(p.join(turnDir(chatId, turnId).path, 'manifest.json'));

  /// Путь бэкапа для [WriteFileOp] во время записи (не рядом с исходным файлом).
  String stagingBackupPath(String chatId, String turnId, String toolRunId) =>
      p.join(stagingDir(chatId, turnId).path, '$toolRunId.stg');

  /// Каталог staging создаётся отдельно от [save]/[writeBackup]: Host делает `cp`
  /// в этот путь только при перезаписи существующего файла.
  Future<void> ensureStagingDir(String chatId, String turnId) async {
    final dir = stagingDir(chatId, turnId);
    final created = !dir.existsSync();
    await dir.create(recursive: true);
    if (created) FilePermissions.directory(dir);
  }

  File backupFile(String chatId, String turnId, String backupName) =>
      File(p.join(backupsDir(chatId, turnId).path, backupName));

  Future<TurnChangeset?> load(String chatId, String turnId) async {
    final file = manifestFile(chatId, turnId);
    if (!file.existsSync()) return null;
    final raw = await file.readAsString();
    return TurnChangeset.fromEncoded(raw);
  }

  Future<TurnChangeset> save(TurnChangeset changeset) async {
    final dir = turnDir(changeset.chatId, changeset.turnId);
    final createdDir = !dir.existsSync();
    await dir.create(recursive: true);
    if (createdDir) FilePermissions.directory(dir);
    final backups = backupsDir(changeset.chatId, changeset.turnId);
    final createdBackups = !backups.existsSync();
    await backups.create(recursive: true);
    if (createdBackups) FilePermissions.directory(backups);
    final manifest = manifestFile(changeset.chatId, changeset.turnId);
    final createdManifest = !manifest.existsSync();
    await manifest.writeAsString(changeset.encode());
    if (createdManifest) FilePermissions.file(manifest);
    return changeset;
  }

  Future<void> writeBackup(
    String chatId,
    String turnId,
    String backupName,
    Uint8List bytes,
  ) async {
    final dir = backupsDir(chatId, turnId);
    final createdDir = !dir.existsSync();
    await dir.create(recursive: true);
    if (createdDir) FilePermissions.directory(dir);
    final file = backupFile(chatId, turnId, backupName);
    final createdFile = !file.existsSync();
    await file.writeAsBytes(bytes, flush: true);
    if (createdFile) FilePermissions.file(file);
  }

  Future<Uint8List?> readBackup(
    String chatId,
    String turnId,
    String backupName,
  ) async {
    final file = backupFile(chatId, turnId, backupName);
    if (!file.existsSync()) return null;
    return file.readAsBytes();
  }

  Future<void> deleteTurn(String chatId, String turnId) async {
    final dir = turnDir(chatId, turnId);
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  Future<void> deleteChat(String chatId) async {
    final dir = Directory(p.join(rootDir.path, 'chats', chatId, 'turns'));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  Future<Map<String, TurnChangeset>> loadForChat(String chatId) async {
    final turnsRoot = Directory(p.join(rootDir.path, 'chats', chatId, 'turns'));
    if (!turnsRoot.existsSync()) return {};
    final out = <String, TurnChangeset>{};
    await for (final entity in turnsRoot.list()) {
      if (entity is! Directory) continue;
      final turnId = p.basename(entity.path);
      final cs = await load(chatId, turnId);
      if (cs != null) out[turnId] = cs;
    }
    return out;
  }

  /// Сохраняет UTF-8 текст в снимок.
  Future<void> writeBackupText(
    String chatId,
    String turnId,
    String backupName,
    String text,
  ) => writeBackup(
    chatId,
    turnId,
    backupName,
    Uint8List.fromList(utf8.encode(text)),
  );
}
