/// Политика паритета опций для «основных команд» из [README.md](../README.md)
/// (раздел «Основные команды»): какие флаги апплет намеренно разбирает и какие
/// пробелы относительно `git … --git-completion-helper` / `-h` считаются ожидаемыми.
///
/// Источник списка поддерживаемых флагов — вызовы [parseGitArgs] в [GitApplet]
/// (`lib/src/git_applet.dart`) и [gitExtraCommand] (`lib/src/git_extra_commands.dart`).
/// При добавлении опции в код пополняйте [supportedOptionLabels]. Если опцию
/// сознательно не поддерживаете, зафиксируйте это в [expectedOptionGaps].
library;

/// Команды из README «Основные команды» (без графических: `citool`, `gitk`, `gui`).
const readmeMainCommands = <String>[
  'add',
  'am',
  'archive',
  'backfill',
  'bisect',
  'branch',
  'bundle',
  'checkout',
  'cherry-pick',
  'clean',
  'clone',
  'commit',
  'describe',
  'diff',
  'fetch',
  'format-patch',
  'gc',
  'grep',
  'init',
  'log',
  'maintenance',
  'merge',
  'mv',
  'notes',
  'pull',
  'push',
  'range-diff',
  'rebase',
  'reset',
  'restore',
  'revert',
  'rm',
  'scalar',
  'shortlog',
  'show',
  'sparse-checkout',
  'stash',
  'status',
  'submodule',
  'switch',
  'tag',
  'worktree',
];

/// Метки опций как у [ _HelpOption.label ] в `parity_report.dart`: `--name` или `-x`.
const supportedOptionLabels = <String, Set<String>>{
  'add': {'--all', '-A', '--update', '-u', '--force', '-f'},
  'am': {
    '--interactive',
    '-i',
    '--no-verify',
    '-n',
    '--verify',
    '--3way',
    '-3',
    '--quiet',
    '-q',
    '--signoff',
    '-s',
    '--utf8',
    '-u',
    '--keep',
    '-k',
    '--keep-non-patch',
    '--message-id',
    '-m',
    '--keep-cr',
    '--scissors',
    '-c',
    '--quoted-cr',
    '--whitespace',
    '--ignore-space-change',
    '--ignore-whitespace',
    '--directory',
    '--exclude',
    '--include',
    '-C',
    '-p',
    '--patch-format',
    '--reject',
    '--resolvemsg',
    '--continue',
    '--resolved',
    '-r',
    '--skip',
    '--abort',
    '--quit',
    '--show-current-patch',
    '--retry',
    '--allow-empty',
    '--committer-date-is-author-date',
    '--ignore-date',
    '--rerere-autoupdate',
    '--gpg-sign',
    '-S',
    '--empty',
  },
  'archive': {'--output', '-o', '--format'},
  'backfill': {'--min-batch-size', '--sparse'},
  'bisect': <String>{},
  'branch': {
    '--delete',
    '-d',
    '--force-delete',
    '-D',
    '--force',
    '-f',
    '--move',
    '-m',
    '--force-move',
    '-M',
    '--all',
    '-a',
    '--show-current',
  },
  'bundle': <String>{},
  'checkout': {'--branch', '-b', '--force-branch', '-B', '--force', '-f'},
  'cherry-pick': {'--continue', '--abort'},
  'clean': {
    '--force',
    '-f',
    '--dry-run',
    '-n',
    '--directories',
    '-d',
    '--remove-ignored',
    '-x',
  },
  'clone': {
    '--quiet',
    '-q',
    '--branch',
    '-b',
    '--origin',
    '-o',
    '--depth',
    '--filter',
    '--bare',
  },
  'commit': {
    '--message',
    '-m',
    '--file',
    '-F',
    '--allow-empty',
    '--all',
    '-a',
    '--amend',
    '--author',
  },
  'describe': {'--tags'},
  'diff': {'--staged', '--cached', '--stat', '--name-only'},
  'fetch': {
    '--dry-run',
    '--quiet',
    '-q',
    '--depth',
    '--filter',
    '--prune',
    '--tags',
  },
  'format-patch': {'--stdout', '-o', '--output-directory'},
  'gc': <String>{},
  'grep': <String>{},
  'init': {
    '--quiet',
    '-q',
    '--bare',
    '--initial-branch',
    '-b',
    '--object-format',
  },
  'log': {
    '--max-count',
    '-n',
    '--oneline',
    '--first-parent',
    '--all',
    '--patch',
    '-p',
    '--author',
    '--grep',
  },
  'maintenance run': {'--auto', '--detach', '--schedule', '--quiet', '--task'},
  'maintenance is-needed': {'--auto', '--task'},
  'maintenance start': {'--scheduler'},
  'maintenance stop': <String>{},
  'maintenance register': {'--config-file'},
  'maintenance unregister': {'--config-file'},
  'merge': {'--continue', '--abort', '--message', '-m', '--ff-only', '--no-ff'},
  'mv': <String>{},
  'notes': {'--message', '-m'},
  'pull': {'--dry-run', '--quiet', '-q', '--ff-only', '--no-ff', '--rebase'},
  'push': {
    '--dry-run',
    '--quiet',
    '-q',
    '--force',
    '-f',
    '--set-upstream',
    '-u',
  },
  'range-diff': <String>{},
  'rebase': {'--onto', '--continue', '--abort'},
  'reset': {'--soft', '--mixed', '--hard'},
  'restore': {'--staged', '--worktree', '--source', '-s'},
  'revert': <String>{},
  'rm': {'--cached', '--recursive', '-r'},
  'scalar clone': {
    '--branch',
    '--full-clone',
    '--single-branch',
    '--src',
    '--tags',
    '--maintenance',
  },
  'scalar register': {'--maintenance'},
  'scalar run': <String>{},
  'scalar reconfigure': {'--all', '--maintenance', '-a'},
  'scalar list': <String>{},
  'scalar unregister': <String>{},
  'scalar delete': <String>{},
  'scalar diagnose': <String>{},
  'scalar help': <String>{},
  'scalar version': <String>{},
  'shortlog': {'--summary', '-s'},
  'show': {'--oneline'},
  'sparse-checkout': <String>{},
  'stash': {
    '--include-untracked',
    '-u',
    '--message',
    '-m',
    '--keep-index',
    '--index',
  },
  'status': {
    '--short',
    '-s',
    '--branch',
    '-b',
    '--porcelain',
    '--ignored',
    '--untracked-files',
    '-u',
  },
  'submodule': <String>{},
  'switch': {
    '--create',
    '-c',
    '--force-create',
    '-C',
    '--discard-changes',
    '--force',
    '-f',
    '--detach',
    '-d',
  },
  'tag': {
    '--delete',
    '-d',
    '--annotate',
    '-a',
    '--message',
    '-m',
    '--force',
    '-f',
    '--list',
    '-l',
  },
  'worktree': {'--branch', '-b'},
};

typedef ParityGapRule = ({String pattern, String reason});

const expectedOptionGaps = <String, List<ParityGapRule>>{
  'add': [
    (
      pattern: '*',
      reason:
          'подмножество индексации: без интерактива, pathspec-from-file, chmod',
    ),
  ],
  'am': [
    (
      pattern: '--interactive',
      reason: 'интерактивный режим в virtual_git не поддерживается',
    ),
    (pattern: '-i', reason: 'см. --interactive'),
    (pattern: '--no-verify', reason: 'хуки applypatch-msg не вызываются'),
    (pattern: '-n', reason: 'см. --no-verify'),
    (pattern: '--verify', reason: 'см. --no-verify'),
    (
      pattern: '--quoted-cr',
      reason: 'разбор quoted-cr кроме nowarn не реализован',
    ),
    (
      pattern: '--whitespace',
      reason: 'для значений кроме nowarn детекция пробелов как у git apply не реализована',
    ),
    (pattern: '--reject', reason: 'файлы *.rej не создаются'),
    (pattern: '--rerere-autoupdate', reason: 'rerere в virtual_git нет'),
    (pattern: '--gpg-sign', reason: 'подпись коммитов GPG не поддерживается'),
    (pattern: '-S', reason: 'см. --gpg-sign'),
    (
      pattern: '--utf8',
      reason: 'перекодирование в UTF-8 как у git-mailinfo не выполняется',
    ),
    (pattern: '-u', reason: 'см. --utf8'),
    (pattern: '--keep-non-patch', reason: 'флаг mailinfo -b не пробрасывается'),
  ],
  'archive': [
    (pattern: '*', reason: 'локальный tar по дереву без remote/exec/add-file'),
  ],
  'bisect': [
    (pattern: '*', reason: 'минимальная запись шагов без полной машины bisect'),
  ],
  'branch': [
    (
      pattern: '*',
      reason: 'ветки без column/format/sort и расширенного списка tracking',
    ),
  ],
  'bundle': [
    (pattern: '*', reason: 'create|verify|unbundle без дополнительных флагов'),
  ],
  'checkout': [
    (pattern: '*', reason: 'переключение ветки без pathspec/merge/track'),
  ],
  'cherry-pick': [
    (pattern: '*', reason: 'один коммит и sequencer без стратегий и подписи'),
  ],
  'clean': [(pattern: '*', reason: 'без интерактива и масок exclude')],
  'clone': [
    (
      pattern: '*',
      reason: 'HTTP(S) и file, shallow и filter; без зеркала и расширенного протокола',
    ),
  ],
  'commit': [
    (
      pattern: '*',
      reason: 'сообщение и amend без редактора, хуков, GPG и сложного pathspec',
    ),
  ],
  'describe': [(pattern: '*', reason: 'упрощённый describe только с --tags')],
  'diff': [
    (pattern: '*', reason: 'ограниченный вывод без полного движка diff git'),
  ],
  'fetch': [
    (
      pattern: '*',
      reason: 'загрузка через package:http без multi-remote и refmap',
    ),
  ],
  'format-patch': [
    (
      pattern: '*',
      reason: 'mbox от одного коммита (--stdout, -N, -o) без обложки, thread и MIME',
    ),
  ],
  'gc': [(pattern: '*', reason: 'вызов prune без опций верхнего уровня gc')],
  'grep': [
    (pattern: '*', reason: 'поиск подстроки в HEAD без regexp-движка git grep'),
  ],
  'init': [(pattern: '*', reason: 'init без shared/template/separate-git-dir')],
  'log': [
    (pattern: '*', reason: 'журнал без decorate/mailmap и ограничений -L'),
  ],
  'maintenance run': [
    (
      pattern: '*',
      reason: 'задача gc и no-op для остального; без фона и lock как в git',
    ),
  ],
  'maintenance is-needed': [(pattern: '*', reason: 'заглушка is-needed')],
  'maintenance start': [
    (pattern: '*', reason: 'нет регистрации планировщика ОС'),
  ],
  'maintenance stop': [(pattern: '*', reason: 'нет фонового процесса')],
  'maintenance register': [
    (pattern: '*', reason: 'регистрация в cron/systemd не моделируется'),
  ],
  'maintenance unregister': [(pattern: '*', reason: 'см. register')],
  'merge': [
    (pattern: '*', reason: 'слияние без GPG, кастомных стратегий и verify'),
  ],
  'mv': [(pattern: '*', reason: 'перемещение без dry-run')],
  'notes': [(pattern: '*', reason: 'add/show с -m без namespaces')],
  'pull': [
    (pattern: '*', reason: 'merge/ff без rebase (rebase отклоняется явно)'),
  ],
  'push': [(pattern: '*', reason: 'HTTP(S) push без зеркал и опций сервера')],
  'range-diff': [
    (pattern: '*', reason: 'упрощённое сравнение списков коммитов'),
  ],
  'rebase': [
    (pattern: '*', reason: 'rebase с --onto и sequencer без интерактива'),
  ],
  'reset': [(pattern: '*', reason: 'режимы и пути без merge и keep')],
  'restore': [(pattern: '*', reason: 'restore без merge и batch path')],
  'revert': [(pattern: '*', reason: 'один revert без -m')],
  'rm': [(pattern: '*', reason: 'rm без force из git')],
  'scalar clone': [
    (
      pattern: '*',
      reason: 'клон с filter и частью флагов scalar без полного CLI',
    ),
  ],
  'scalar register': [
    (pattern: '*', reason: 'минимальная регистрация зачисления'),
  ],
  'scalar run': [(pattern: '*', reason: 'запуск maintenance-task')],
  'scalar reconfigure': [(pattern: '*', reason: 'заглушка reconfigure')],
  'scalar list': [(pattern: '*', reason: 'заглушка')],
  'scalar unregister': [(pattern: '*', reason: 'заглушка')],
  'scalar delete': [(pattern: '*', reason: 'заглушка')],
  'scalar diagnose': [
    (pattern: '*', reason: 'диагностика машины вне scope пакета'),
  ],
  'scalar help': [(pattern: '*', reason: 'краткая справка')],
  'scalar version': [
    (pattern: '*', reason: 'строка версии без verbose и build-options'),
  ],
  'shortlog': [(pattern: '*', reason: 'подсчёт авторов без email/group')],
  'show': [(pattern: '*', reason: 'упрощённый show')],
  'sparse-checkout': [
    (pattern: '*', reason: 'init/set/list по файлу без cone'),
  ],
  'stash': [(pattern: '*', reason: 'ограниченный набор подкоманд и флагов')],
  'status': [(pattern: '*', reason: 'без column и расширенного porcelain')],
  'submodule': [
    (pattern: '*', reason: 'только submodule add без update и процессов хоста'),
  ],
  'switch': [(pattern: '*', reason: 'переключение без submodule/recurse')],
  'tag': [(pattern: '*', reason: 'без verify и произвольных форматов')],
  'worktree': [(pattern: '*', reason: 'add/list/remove без lock/prune')],
};

/// Префикс политики: верхний уровень команды или `команда подкоманда`.
String policyPrefix(String command, List<String> argvTail) {
  if (argvTail.isEmpty) return command;
  if (command == 'maintenance') {
    return 'maintenance ${argvTail.first}';
  }
  if (command == 'scalar') {
    return 'scalar ${argvTail.first}';
  }
  return command;
}

bool _ruleMatches(String label, ParityGapRule rule) =>
    rule.pattern == '*' || rule.pattern == label;

/// Опция входит в политику «поддержана» для данного префикса.
bool isSupportedByPolicy(String prefix, String label) {
  final set = supportedOptionLabels[prefix];
  if (set == null) return false;
  return set.contains(label);
}

/// Опция учитывается как ожидаемый пробел (не считается регрессией в режиме политики).
bool isExpectedGap(String prefix, String label) {
  if (isSupportedByPolicy(prefix, label)) return false;
  final rules = expectedOptionGaps[prefix];
  if (rules == null) return false;
  return rules.any((rule) => _ruleMatches(label, rule));
}

/// Текст причины для ожидаемого пробела или null.
String? expectedGapReason(String prefix, String label) {
  final rules = expectedOptionGaps[prefix];
  if (rules == null) return null;
  for (final rule in rules) {
    if (rule.pattern == label) return rule.reason;
  }
  for (final rule in rules) {
    if (rule.pattern == '*') return rule.reason;
  }
  return null;
}
