/// Текст `git status` и сухой прогон `git commit`: длинный, короткий и заголовок ветки.
///
/// Формат совпадает с git 2.53 при `LC_ALL=C` и без цвета. Подсказка про скрытые
/// неотслеживаемые файлы нужна `git commit -uno`: обычный `git status` её не печатает.
library;

import 'package:virtual_git/src/git_status.dart';
import 'package:virtual_host/virtual_host.dart';

/// Длинный статус. [mentionHiddenUntracked] добавляет строку `commit -uno`,
/// если неотслеживаемые есть, но список скрыт. [unbornHeading] — `No commits yet`
/// у `git status` и `Initial commit` у `git commit`.
///
/// [sequencerAction] (`cherry-pick` или `revert`) и [sequencerAbbr] печатают
/// блок «you are currently …», как git, пока операция не завершена. Текст
/// «all conflicts fixed» совпадает с пустым патчем; конфликтный rebase этот
/// блок не включает.
void writeGitLongStatus(
  AppletIo io, {
  required String? branch,
  required bool committed,
  required GitStatus report,
  required bool showUntracked,
  bool mentionHiddenUntracked = false,
  String unbornHeading = 'No commits yet',
  String? sequencerAction,
  String? sequencerAbbr,
}) {
  io.stdout.writeText(
    branch == null ? 'HEAD detached\n' : 'On branch $branch\n',
  );
  if (sequencerAction != null && sequencerAbbr != null) {
    _writeSequencerHint(io, sequencerAction, sequencerAbbr);
  }
  final staged = [
    for (final entry in report.entries)
      if (entry.isStaged) entry,
  ];
  final unstaged = [
    for (final entry in report.entries)
      if (entry.isUnstaged && !entry.isUntracked && !entry.isIgnored) entry,
  ];
  final untracked = [
    for (final entry in report.entries)
      if (showUntracked && entry.isUntracked) entry,
  ];
  final hiddenUntracked =
      !showUntracked && report.entries.any((entry) => entry.isUntracked);
  if (staged.isEmpty && unstaged.isEmpty && untracked.isEmpty) {
    if (!committed) {
      io.stdout.writeText(
        '\n$unbornHeading\n\n'
        'nothing to commit (create/copy files and use "git add" to track)\n',
      );
      return;
    }
    io.stdout.writeText('nothing to commit, working tree clean\n');
    _hiddenUntrackedHint(io, hiddenUntracked && mentionHiddenUntracked);
    return;
  }
  if (!committed) io.stdout.writeText('\n$unbornHeading\n');
  final lead = committed ? '' : '\n';
  if (staged.isNotEmpty) {
    final unstage = committed
        ? 'git restore --staged <file>...'
        : 'git rm --cached <file>...';
    io.stdout.writeText(
      '${lead}Changes to be committed:\n'
      '  (use "$unstage" to unstage)\n',
    );
    for (final entry in staged) {
      io.stdout.writeText(
        '\t${gitStatusLongLabel(entry.indexStatus)}${entry.path}\n',
      );
    }
  }
  if (unstaged.isNotEmpty) {
    final beforeUnstaged = staged.isEmpty ? lead : '\n';
    io.stdout.writeText(
      '${beforeUnstaged}Changes not staged for commit:\n'
      '  (use "git add <file>..." to update what will be committed)\n'
      '  (use "git restore <file>..." to discard changes in working directory)\n',
    );
    for (final entry in unstaged) {
      io.stdout.writeText(
        '\t${gitStatusLongLabel(entry.workTreeStatus)}${entry.path}\n',
      );
    }
  }
  if (untracked.isNotEmpty) {
    final beforeUntracked = staged.isEmpty && unstaged.isEmpty ? lead : '\n';
    io.stdout.writeText(
      '${beforeUntracked}Untracked files:\n'
      '  (use "git add <file>..." to include in what will be committed)\n',
    );
    for (final entry in untracked) {
      io.stdout.writeText('\t${entry.path}\n');
    }
  }
  if (staged.isEmpty && untracked.isNotEmpty && unstaged.isEmpty) {
    io.stdout.writeText(
      '\nnothing added to commit but untracked files present (use "git add" to track)\n',
    );
  } else if (staged.isEmpty && unstaged.isNotEmpty) {
    io.stdout.writeText(
      '\nno changes added to commit (use "git add" and/or "git commit -a")\n',
    );
  }
  final hinted = hiddenUntracked && mentionHiddenUntracked;
  final footer =
      staged.isEmpty && (untracked.isNotEmpty || unstaged.isNotEmpty);
  _hiddenUntrackedHint(io, hinted);
  if (!hinted &&
      !footer &&
      (staged.isNotEmpty || unstaged.isNotEmpty || untracked.isNotEmpty)) {
    io.stdout.writeText('\n');
  }
}

void _writeSequencerHint(AppletIo io, String action, String abbr) {
  final verb = action == 'revert' ? 'reverting' : 'cherry-picking';
  io.stdout.writeText(
    'You are currently $verb commit $abbr.\n'
    '  (all conflicts fixed: run "git $action --continue")\n'
    '  (use "git $action --skip" to skip this patch)\n'
    '  (use "git $action --abort" to cancel the $action operation)\n'
    '\n',
  );
}

void _hiddenUntrackedHint(AppletIo io, bool show) {
  if (!show) return;
  io.stdout.writeText(
    '\nUntracked files not listed (use -u option to show untracked files)\n',
  );
}

/// Короткий и porcelain v1. [terminator] — `\n` или NUL для `-z`.
void writeGitShortStatus(
  AppletIo io,
  GitStatus report, {
  required bool showUntracked,
  String terminator = '\n',
}) {
  final changes = <GitStatusEntry>[];
  final untracked = <GitStatusEntry>[];
  final ignored = <GitStatusEntry>[];
  for (final entry in report.entries) {
    if (entry.isUntracked) {
      untracked.add(entry);
    } else if (entry.isIgnored) {
      ignored.add(entry);
    } else if (entry.indexStatus != GitFileStatus.unchanged ||
        entry.workTreeStatus != GitFileStatus.unchanged) {
      changes.add(entry);
    }
  }
  for (final entry in changes) {
    io.stdout.writeText(
      '${gitStatusLetter(entry.indexStatus)}${gitStatusLetter(entry.workTreeStatus)} ${entry.path}$terminator',
    );
  }
  if (showUntracked) {
    for (final entry in untracked) {
      io.stdout.writeText('?? ${entry.path}$terminator');
    }
  }
  for (final entry in ignored) {
    io.stdout.writeText('!! ${entry.path}$terminator');
  }
}

/// Строка `##` для `--short --branch` и porcelain. [tracking] — хвост
/// `...upstream [ahead N]` без префикса `##`.
void writeGitBranchHeader(
  AppletIo io,
  String? branch, {
  required bool committed,
  String tracking = '',
  String terminator = '\n',
}) {
  if (branch == null) {
    io.stdout.writeText('## HEAD (no branch)$terminator');
    return;
  }
  if (!committed) {
    io.stdout.writeText('## No commits yet on $branch$terminator');
    return;
  }
  io.stdout.writeText('## $branch$tracking$terminator');
}

/// Подпись файла в длинном статусе, с выравниванием как у git.
String gitStatusLongLabel(GitFileStatus status) => switch (status) {
  GitFileStatus.added => 'new file:   ',
  GitFileStatus.modified => 'modified:   ',
  GitFileStatus.deleted => 'deleted:    ',
  GitFileStatus.conflicted => 'both modified:   ',
  GitFileStatus.unchanged ||
  GitFileStatus.untracked ||
  GitFileStatus.ignored => 'modified:   ',
};

/// Буква XY-статуса.
String gitStatusLetter(GitFileStatus status) => switch (status) {
  GitFileStatus.unchanged => ' ',
  GitFileStatus.added => 'A',
  GitFileStatus.modified => 'M',
  GitFileStatus.deleted => 'D',
  GitFileStatus.conflicted => 'U',
  GitFileStatus.untracked => '?',
  GitFileStatus.ignored => '!',
};
