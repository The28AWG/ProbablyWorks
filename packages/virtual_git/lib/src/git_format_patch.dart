// ignore_for_file: avoid-substring
// Причина: темы, хеши и base85 режутся по байтам ASCII, как в git.
/// `git format-patch`: серия писем mbox из диапазона коммитов.
///
/// Неизвестная опция — код 129. Опция, которую апплет разобрал, но не может
/// выполнить (неверный режим, нет диапазона для range-diff), пишет `fatal`
/// и завершается с кодом 128, а не молчит.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:virtual_git/src/git_cli.dart';
import 'package:virtual_git/src/git_commit.dart';
import 'package:virtual_git/src/git_diff.dart';
import 'package:virtual_git/src/git_diff_codec.dart';
import 'package:virtual_git/src/git_log.dart';
import 'package:virtual_git/src/git_path.dart' as p;
import 'package:virtual_git/src/git_repository.dart';
import 'package:virtual_git/src/git_text_diff.dart';
import 'package:virtual_host/virtual_host.dart';
part 'command/format_patch_diff.dart';
part 'command/format_patch_mail.dart';
part 'command/format_patch_select.dart';

const _usage =
    'usage: git format-patch [<options>] [<since> | <revision-range>]';

const _emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

const _mboxFromDate = 'Mon Sep 17 00:00:00 2001';

/// Версия в подписи и в MIME-границе. Совпадает с `git version` апплета.
const _versionMarker = '0.1.0';

const _defaultFilenameMax = 63;

const _coverModes = {'message', 'default', 'subject', 'auto', 'none'};

/// Собирает серию патчей и пишет её в stdout или в файлы.
Future<int> runFormatPatch(
  AppletIo io,
  List<String> args,
  List<({String key, String value})> config,
) async {
  final counted = _takeCount(args);
  _rejectUnknown(counted.args);
  final prepared = _prepareArgs(counted.args);
  final parsed = parseGitArgs(prepared, _formatPatchOptions, usage: _usage);
  final opts = _FpOptions(parsed, counted.maxCount, config, prepared);
  final repo = await _open(io);
  _validate(opts);

  final selected = await _selectCommits(repo, opts);
  if (selected.isEmpty) return 0;

  final commits = await _filterUpstream(repo, opts, selected);
  if (commits.isEmpty) return 0;
  if (opts.hasCreationFactor && opts.rangeDiff == null) {
    throw const GitUsage(
      "fatal: the option '--creation-factor' requires '--range-diff'\n",
      exitCode: 128,
    );
  }

  final showCover = _coverEnabled(opts, commits.length);
  if (!showCover &&
      commits.length > 1 &&
      (opts.rangeDiff != null || opts.interdiff != null)) {
    final flag = opts.rangeDiff != null ? '--range-diff' : '--interdiff';
    throw GitUsage(
      'fatal: $flag requires --cover-letter or single patch\n',
      exitCode: 128,
    );
  }
  final numbered = _numbered(opts, commits.length, cover: showCover);
  final total = opts.startNumber + commits.length - 1;
  final actor = _actor(io, config, committer: true);
  final signature = await _signatureText(io, repo, opts);
  final description = await _description(io, opts);
  final unix = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final paths = opts.paths.isEmpty ? null : opts.paths;

  final rendered = <_Mail>[];
  if (showCover) {
    rendered.add(
      await _cover(
        repo,
        opts,
        commits,
        actor: actor,
        numbered: numbered,
        total: total,
        description: description,
        signature: signature,
        unix: unix,
        paths: paths,
      ),
    );
  }
  for (var index = 0; index < commits.length; index++) {
    final number = opts.startNumber + index;
    rendered.add(
      await _patchMail(
        repo,
        opts,
        commits[index],
        actor: actor,
        number: number,
        total: total,
        numbered: numbered,
        signature: signature,
        unix: unix,
        paths: paths,
        baseOnThis: !showCover && index == 0,
        extrasOnThis: !showCover && commits.length == 1,
      ),
    );
  }
  _thread(rendered, opts);

  if (opts.stdout) {
    final buffer = StringBuffer();
    for (var index = 0; index < rendered.length; index++) {
      // Между письмами — пустая строка. После Interdiff/Range-diff git её
      // не вставляет: следующий From идёт сразу за последней строкой diff.
      final previous = index == 0 ? '' : rendered[index - 1].text;
      final glued =
          previous.contains('\nInterdiff:\n') ||
          previous.contains('\nRange-diff:\n');
      if (index > 0 && !glued) buffer.writeln();
      buffer.write(rendered[index].text);
    }
    io.stdout.writeText(buffer.toString());
    return 0;
  }

  final outDir = opts.outputDirectory;
  if (outDir != null) {
    final dir = outDir.startsWith('/') ? outDir : p.join(io.cwd, outDir);
    await io.fs.mkdir(dir, recursive: true);
  }
  for (final mail in rendered) {
    final full = outDir == null
        ? p.join(io.cwd, mail.fileName)
        : p.join(io.cwd, outDir, mail.fileName);
    await io.fs.writeBytes(full, Uint8List.fromList(utf8.encode(mail.text)));
    if (!opts.quiet) {
      final listed = outDir == null
          ? mail.fileName
          : p.join(outDir, mail.fileName);
      io.stdout.writeText('$listed\n');
    }
  }
  return 0;
}
