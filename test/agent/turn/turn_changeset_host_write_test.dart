import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pw_agent/agent/turn/host_write_backup_path.dart';
import 'package:pw_agent/agent/turn/turn_changeset.dart';
import 'package:pw_agent/agent/turn/turn_changeset_store.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/host_op.dart';
import 'package:pw_agent/host/host_runtime.dart';
import 'package:pw_agent/host/local_host_runtime.dart';

final _runtime = LocalHostRuntime(os: HostOs.posix);

Future<int?> _runWrite({
  required String targetPath,
  required String backupPath,
  required String? expectedMtime,
  required String content,
}) async {
  int? code;
  await for (final event in _runtime.perform(
    WriteFileOp(
      targetPath,
      backupPath: backupPath,
      expectedMtime: expectedMtime,
    ),
    stdin: Uint8List.fromList(utf8.encode(content)),
  )) {
    if (event case ExecDone(:final exitCode)) code = exitCode;
  }
  return code;
}

Future<String> _mtime(String path) async {
  int? code;
  final out = StringBuffer();
  await for (final event in _runtime.perform(StatOp(path))) {
    switch (event) {
      case ExecStdout e:
        out.write(utf8.decode(e.bytes));
      case ExecDone(:final exitCode):
        code = exitCode;
      default:
    }
  }
  expect(code, 0);
  return StatResult.parse(out.toString())!.mtime;
}

void main() {
  test('overwrite fails if app staging dir is missing', () async {
    final dataRoot = Directory.systemTemp.createTempSync('pw_turn_data_');
    final workDir = Directory.systemTemp.createTempSync('pw_turn_work_');
    addTearDown(() {
      dataRoot.deleteSync(recursive: true);
      workDir.deleteSync(recursive: true);
    });
    final store = TurnChangesetStore(dataRoot);
    const chatId = 'chat';
    const turnId = 'turn';
    const runId = 'run';
    await store.save(
      TurnChangeset(chatId: chatId, turnId: turnId, updatedAt: DateTime.now()),
    );
    final target = File('${workDir.path}/f.txt')..writeAsStringSync('old');
    final mtime = await _mtime(target.path);
    final stagingPath = hostWriteBackupPath(
      hostKind: HostKind.local,
      targetPath: target.path,
      runId: runId,
      appStagingPath: store.stagingBackupPath(chatId, turnId, runId),
    );
    expect(Directory(p.dirname(stagingPath)).existsSync(), isFalse);

    final code = await _runWrite(
      targetPath: target.path,
      backupPath: stagingPath,
      expectedMtime: mtime,
      content: 'new',
    );
    expect(code, isNot(0));
    expect(target.readAsStringSync(), 'old');
  });

  test('overwrite succeeds after ensureStagingDir', () async {
    final dataRoot = Directory.systemTemp.createTempSync('pw_turn_data_');
    final workDir = Directory.systemTemp.createTempSync('pw_turn_work_');
    addTearDown(() {
      dataRoot.deleteSync(recursive: true);
      workDir.deleteSync(recursive: true);
    });
    final store = TurnChangesetStore(dataRoot);
    const chatId = 'chat';
    const turnId = 'turn';
    const runId = 'run';
    await store.save(
      TurnChangeset(chatId: chatId, turnId: turnId, updatedAt: DateTime.now()),
    );
    await store.ensureStagingDir(chatId, turnId);
    final target = File('${workDir.path}/f.txt')..writeAsStringSync('old');
    final mtime = await _mtime(target.path);
    final stagingPath = hostWriteBackupPath(
      hostKind: HostKind.local,
      targetPath: target.path,
      runId: runId,
      appStagingPath: store.stagingBackupPath(chatId, turnId, runId),
    );

    final code = await _runWrite(
      targetPath: target.path,
      backupPath: stagingPath,
      expectedMtime: mtime,
      content: 'new',
    );
    expect(code, 0);
    expect(target.readAsStringSync(), 'new');
    expect(
      File(stagingPath).readAsStringSync(),
      'old',
      reason: 'host backup lands in app staging',
    );
  });

  test('ssh host uses remote temp, not app data path', () {
    final store = TurnChangesetStore(
      Directory.systemTemp.createTempSync('pw_turn_ssh_'),
    );
    final appStaging = store.stagingBackupPath('c', 't', 'run');
    expect(
      hostWriteBackupPath(
        hostKind: HostKind.ssh,
        targetPath: '/var/www/a.txt',
        runId: 'run',
        appStagingPath: appStaging,
      ),
      '/tmp/pw-stg-run',
    );
  });
}
