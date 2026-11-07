// ignore_for_file: avoid-substring
// Причина: шаблоны и пути режутся по индексам разбора, это не пользовательский текст.
/// `git grep`: строки tracked-файлов, индекса, деревьев и `--no-index`.
///
/// Регулярные выражения — POSIX BRE (по умолчанию) и ERE (`-E`); `-F` ищет
/// фиксированную строку. Образцы комбинируются `--and` / `--or` / `--not`
/// и скобками, пустой образец совпадает с каждой строкой.
/// PCRE, цвет, pager, textconv, потоки, function-context и submodule
/// в разбор не входят: `error: unknown option`, код 129.
library;

import 'dart:typed_data';

import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_host_io.dart';
import 'package:virtual_git/src/git_index.dart';
import 'package:virtual_git/src/git_object_type.dart';
import 'package:virtual_git/src/git_path.dart' as p;
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_host/virtual_host.dart';
part 'command/grep_expr.dart';
part 'command/grep_parse.dart';
part 'command/grep_search.dart';

/// Ищет образец так же, как `git grep` в `LC_ALL=C`, и возвращает код выхода.
///
/// 0 — есть совпадение (для `-L` — есть файл без совпадения), 1 — нет,
/// 128 — фатальная ошибка, 129 — чужая опция или нет значения.
/// Неподдерживаемые флаги справки не прячутся: их нет в разборе, поэтому
/// апплет отвечает `error: unknown option` / `unknown switch`.
Future<int> gitGrep(AppletIo io, List<String> args) async {
  final parsed = await _parse(io, args);
  final expr = parsed.builder.finish();
  if (expr == null) {
    throw const GitUsage('fatal: no pattern given\n', exitCode: 128);
  }
  _rejectConflicts(parsed);
  final repo = await GitRepository.discover(io.cwd);
  if (repo == null && !parsed.noIndex) {
    throw const GitUsage(
      'fatal: not a git repository (or any of the parent directories): .git\n',
      exitCode: 128,
    );
  }
  final cwdPrefix = repo == null ? '' : _cwdPrefix(repo.path, io.cwd);
  final layout = await _layout(
    parsed,
    repo: repo,
    cwd: io.cwd,
    cwdPrefix: cwdPrefix,
  );
  if (parsed.maxCount == 0) return 1;
  _compile(expr, parsed);
  return _search(io, parsed, expr, layout, cwdPrefix: cwdPrefix);
}

const _usage =
    'usage: git grep [<options>] [-e] <pattern> [<rev>...] [[--] <path>...]';
