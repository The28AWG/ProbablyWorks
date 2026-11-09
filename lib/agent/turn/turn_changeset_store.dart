/// Файловое хранилище снимков хода агента (manifest и backups).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:probably_works/agent/turn/turn_changeset.dart';

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
    await dir.create(recursive: true);
    await backupsDir(
      changeset.chatId,
      changeset.turnId,
    ).create(recursive: true);
    await manifestFile(
      changeset.chatId,
      changeset.turnId,
    ).writeAsString(changeset.encode());
    return changeset;
  }

  Future<void> writeBackup(
    String chatId,
    String turnId,
    String backupName,
    Uint8List bytes,
  ) async {
    final dir = backupsDir(chatId, turnId);
    await dir.create(recursive: true);
    await backupFile(
      chatId,
      turnId,
      backupName,
    ).writeAsBytes(bytes, flush: true);
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
