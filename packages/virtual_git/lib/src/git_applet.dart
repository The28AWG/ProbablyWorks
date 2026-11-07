import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_git/src/git_branch_command.dart';
import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_commit_codec.dart';
import 'package:virtual_git/src/git_commit_command.dart';
import 'package:virtual_git/src/git_diff.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_diff_options.dart';
import 'package:virtual_git/src/git_extra_commands.dart';
import 'package:virtual_git/src/git_fetch.dart';
import 'package:virtual_git/src/git_host_io.dart';
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_log.dart';
import 'package:virtual_git/src/git_merge.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_pull.dart';
import 'package:virtual_git/src/git_refspec.dart';
import 'package:virtual_git/src/git_remote.dart';
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_git/src/git_reset.dart';
import 'package:virtual_git/src/git_status_format.dart';
import 'package:virtual_host/virtual_host.dart';
part 'command/applet_inspect.dart';
part 'command/applet_local.dart';
part 'command/applet_sync.dart';
part 'command/applet_text.dart';

/// Команда `git` в оболочке виртуального хоста.
///
/// Аргументы разбираются как у git 2.53 (`LC_ALL=C`): длинные и короткие опции,
/// `--name=value`, `--` и глобальные `-C`/`-c`. Неизвестная опция завершается
/// кодом 129. Автор берётся из окружения, затем из `-c user.*`.
/// `--depth` на `file://` и HTTP обрезает историю и пишет `.git/shallow`.
/// Обычный путь каталога предупреждает и копирует целиком: так же делает git,
/// и в тексте предупреждения он сам предлагает `file://`.
final class GitApplet implements Applet {
  const GitApplet({this.http});

  /// Транспорт сети. Без него запросы идут через [PackageGitHttp].
  final GitHttp? http;

  @override
  String get name => 'git';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    try {
      final global = parseGitGlobals(args, cwd: io.cwd, resolve: _join);
      if (global.version) {
        io.stdout.writeText('git version 0.1.0\n');
        return 0;
      }
      if (global.help || global.args.isEmpty) {
        io.stdout.writeText(gitRootUsage);
        return global.help ? 0 : 1;
      }
      final commandIo = io.copyWith(cwd: global.cwd);
      bindGitIo(
        commandIo.fs,
        cwd: commandIo.cwd,
        environment: commandIo.env,
        http: http,
      );
      try {
        return await _dispatch(commandIo, global);
      } finally {
        clearGitIo();
      }
    } on GitUsage catch (error) {
      io.stderr.writeText(error.message);
      return error.exitCode;
    } on Object catch (error) {
      io.stderr.writeText('fatal: ${_fatalText(error)}\n');
      return 128;
    }
  }

  Future<int> _dispatch(AppletIo io, GitGlobals global) async {
    final command = global.args.first;
    final rest = global.args.sublist(1);
    final extra = await gitExtraCommand(io, command, rest, global.config);
    if (extra != null) return extra;
    return switch (command) {
      'init' => _init(io, rest, bare: global.bare),
      'clone' => _clone(io, rest),
      'status' => _needRepo(io, () => _status(io, rest)),
      'add' => _needRepo(io, () => _add(io, rest)),
      'commit' => _needRepo(io, () => _commit(io, rest, global.config)),
      'log' => _needRepo(io, () => _log(io, rest)),
      'diff' => _needRepo(io, () => _diff(io, rest)),
      'show' => _needRepo(io, () => _show(io, rest)),
      'rev-parse' => _needRepo(io, () => _revParse(io, rest)),
      'ls-files' => _needRepo(io, () => _lsFiles(io, rest)),
      'branch' => _needRepo(io, () => _branch(io, rest, global.config)),
      'tag' => _needRepo(io, () => _tag(io, rest, global.config)),
      'checkout' => _needRepo(io, () => _checkout(io, rest, global.config)),
      'switch' => _needRepo(io, () => _switch(io, rest, global.config)),
      'restore' => _needRepo(io, () => _restore(io, rest)),
      'reset' => _needRepo(io, () => _reset(io, rest, global.config)),
      'merge' => _needRepo(io, () => _merge(io, rest, global.config)),
      'stash' => _needRepo(io, () => _stash(io, rest, global.config)),
      'apply' => _needRepo(io, () => _apply(io, rest)),
      'remote' => _needRepo(io, () => _remote(io, rest)),
      'fetch' => _needRepo(io, () => _fetch(io, rest)),
      'pull' => _needRepo(io, () => _pull(io, rest, global.config)),
      'push' => _needRepo(io, () => _push(io, rest)),
      _ => _unknown(io, command),
    };
  }

  Future<int> _unknown(AppletIo io, String command) {
    io.stderr.writeText(
      "git: '$command' is not a git command. See 'git --help'.\n",
    );
    return Future<int>.value(1);
  }

  /// Сначала репозиторий, потом опции: вне репозитория git отвечает 128,
  /// даже если аргумент сам по себе был бы ошибкой разбора.
  Future<int> _needRepo(AppletIo io, Future<int> Function() body) async {
    await _repo(io);
    return body();
  }

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
}

final class _Network {
  const _Network(this.remote, this.refSpecs);

  final String remote;
  final List<GitRefSpec>? refSpecs;
}
