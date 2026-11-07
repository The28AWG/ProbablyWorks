// ignore_for_file: avoid-substring
// Причина: короткие хеши и fanout LFS режутся по фиксированной длине, как в git.
/// Команды, которых не было в первом разборе апплета.
/// Каждая опирается на публичные методы репозитория и пишет текст git.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_am.dart';
import 'package:virtual_git/src/git_apply.dart';
import 'package:virtual_git/src/git_apply_whitespace.dart';
import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_commit_codec.dart';
import 'package:virtual_git/src/git_commit_command.dart';
import 'package:virtual_git/src/git_diff.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_format_patch.dart';
import 'package:virtual_git/src/git_grep.dart';
import 'package:virtual_git/src/git_hash_algorithm.dart';
import 'package:virtual_git/src/git_host_io.dart' show Directory, File;
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_object.dart';
import 'package:virtual_git/src/git_object_id.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_path.dart' as p;
import 'package:virtual_git/src/git_range_diff.dart';
import 'package:virtual_git/src/git_reference.dart';
import 'package:virtual_git/src/git_remote.dart';
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_git/src/git_reset.dart';
import 'package:virtual_git/src/git_status_format.dart';
import 'package:virtual_host/virtual_host.dart';
part 'command/extra_am.dart';
part 'command/extra_housekeeping.dart';
part 'command/extra_paths.dart';
part 'command/extra_read.dart';
part 'command/extra_replay.dart';

/// Разбирает префикс `scalar` до имени подкоманды: только `-C` и `-c`.
///
/// Остальные флаги относятся к подкоманде. Возвращает [GitGlobals] с [GitGlobals.args]
/// — хвост после глобальных опций. Неизвестный `--флаг` даёт код 129 через [GitUsage].
GitGlobals parseScalarGlobals(
  List<String> args, {
  required String cwd,
  required String Function(String cwd, String path) resolve,
}) {
  var current = cwd;
  final config = <({String key, String value})>[];
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--') {
      return GitGlobals(
        cwd: current,
        bare: false,
        version: false,
        help: false,
        config: config,
        args: args.sublist(index + 1),
      );
    }
    if (!arg.startsWith('-') || arg == '-') {
      return GitGlobals(
        cwd: current,
        bare: false,
        version: false,
        help: false,
        config: config,
        args: args.sublist(index),
      );
    }
    if (arg == '-C' || arg.startsWith('-C')) {
      final inline = arg == '-C' ? null : arg.substring(2);
      final path = inline ?? args[++index];
      current = resolve(current, path);
      continue;
    }
    if (arg == '-c' || arg.startsWith('-c')) {
      final inline = arg == '-c' ? null : arg.substring(2);
      final raw = inline ?? args[++index];
      final eq = raw.indexOf('=');
      if (eq <= 0) {
        throw GitUsage('error: key does not contain a section: $raw\n');
      }
      config.add((key: raw.substring(0, eq), value: raw.substring(eq + 1)));
      continue;
    }
    if (arg.startsWith('--')) {
      throw GitUsage("error: unknown option `${arg.substring(2)}'\n");
    }
    throw GitUsage("error: unknown switch `${arg.substring(1)}'\n");
  }
  return GitGlobals(
    cwd: current,
    bare: false,
    version: false,
    help: false,
    config: config,
    args: const [],
  );
}

/// Возвращает код команды или null, если это не дополнительная команда.
Future<int?> gitExtraCommand(
  AppletIo io,
  String command,
  List<String> args,
  List<({String key, String value})> config,
) => switch (command) {
  'reflog' => _reflog(io, args),
  'check-ignore' => _checkIgnore(io, args),
  'merge-base' => _mergeBase(io, args),
  'show-ref' => _showRef(io, args),
  'worktree' => _worktree(io, args, config),
  'rm' => _rm(io, args),
  'mv' => _mv(io, args),
  'clean' => _clean(io, args),
  'cherry-pick' => _cherryPick(io, args, config),
  'revert' => _revert(io, args, config),
  'rebase' => _rebase(io, args, config),
  'ls-tree' => _lsTree(io, args),
  'cat-file' => _catFile(io, args),
  'config' => _config(io, args),
  'notes' => _notes(io, args, config),
  'replace' => _replace(io, args),
  'blame' => _blame(io, args),
  'grep' => _grep(io, args),
  'describe' => _describe(io, args),
  'bisect' => _bisect(io, args),
  'archive' => _archive(io, args),
  'bundle' => _bundle(io, args),
  'format-patch' => runFormatPatch(io, args, config),
  'am' => _am(io, args, config),
  'fsck' => _fsck(io),
  'prune' => _prune(io),
  'gc' => _gc(io, args),
  'submodule' => _submodule(io, args),
  'sparse-checkout' => _sparse(io, args),
  'lfs' => _lfs(io, args),
  'rev-list' => _revList(io, args),
  'hash-object' => _hashObject(io, args),
  'update-ref' => _updateRef(io, args),
  'symbolic-ref' => _symbolicRef(io, args),
  'commit-tree' => _commitTree(io, args, config),
  'write-tree' => _writeTree(io),
  'merge-file' => _mergeFile(io, args),
  'merge-tree' => _mergeTree(io, args),
  'shortlog' => _shortlog(io, args),
  'name-rev' => _nameRev(io, args),
  'range-diff' => _rangeDiff(io, args),
  'check-attr' => _checkAttr(io, args),
  'check-mailmap' => _checkMailmap(io, args),
  'backfill' => _backfill(io, args),
  'maintenance' => _maintenance(io, args),
  'scalar' => _scalar(io, args, config),
  _ => Future<int?>.value(),
};

Future<GitRepository> _repo(AppletIo io) async {
  final repository = await GitRepository.discover(io.cwd);
  if (repository == null) {
    throw const GitUsage(
      'fatal: not a git repository (or any of the parent directories): .git\n',
      exitCode: 128,
    );
  }
  return repository;
}

GitCommitSignature _signature(
  AppletIo io,
  List<({String key, String value})> config,
) {
  String? env(String key) {
    final value = io.env[key];
    if (value == null || value.isEmpty) return null;
    return value;
  }

  String? configured(String key) {
    for (final item in config) {
      if (item.key == key) return item.value;
    }
    return null;
  }

  final name =
      env('GIT_AUTHOR_NAME') ?? configured('user.name') ?? io.profile.user;
  final email =
      env('GIT_AUTHOR_EMAIL') ??
      configured('user.email') ??
      '$name@${io.profile.hostname}';
  final raw = env('GIT_AUTHOR_DATE') ?? env('GIT_COMMITTER_DATE');
  if (raw != null) {
    final parts = raw.split(' ');
    final seconds = int.tryParse(parts.first);
    if (seconds != null) {
      return GitCommitSignature(
        name: name,
        email: email,
        timestampSeconds: seconds,
        timezoneOffset: parts.length > 1 ? parts[1] : '+0000',
      );
    }
  }
  return GitCommitSignature.fromDateTime(
    name: name,
    email: email,
    timestamp: DateTime.now(),
  );
}

GitCommitSignature _committer(
  AppletIo io,
  List<({String key, String value})> config,
) {
  String? env(String key) {
    final value = io.env[key];
    if (value == null || value.isEmpty) return null;
    return value;
  }

  String? configured(String key) {
    for (final item in config) {
      if (item.key == key) return item.value;
    }
    return null;
  }

  final name =
      env('GIT_COMMITTER_NAME') ??
      env('GIT_AUTHOR_NAME') ??
      configured('user.name') ??
      io.profile.user;
  final email =
      env('GIT_COMMITTER_EMAIL') ??
      env('GIT_AUTHOR_EMAIL') ??
      configured('user.email') ??
      '$name@${io.profile.hostname}';
  final raw = env('GIT_COMMITTER_DATE') ?? env('GIT_AUTHOR_DATE');
  if (raw != null) {
    final parts = raw.split(' ');
    final seconds = int.tryParse(parts.first);
    if (seconds != null) {
      return GitCommitSignature(
        name: name,
        email: email,
        timestampSeconds: seconds,
        timezoneOffset: parts.length > 1 ? parts[1] : '+0000',
      );
    }
  }
  return GitCommitSignature.fromDateTime(
    name: name,
    email: email,
    timestamp: DateTime.now(),
  );
}

String _abbr(String hex) => hex.length <= 7 ? hex : hex.substring(0, 7);
