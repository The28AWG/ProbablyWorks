/// Списки [GitOption] для `git diff` и `git range-diff`.
///
/// В [parseGitArgs] попадают только опции с реализованным поведением.
/// Остальные флаги из справки git дают `error: unknown option` (код 129),
/// как у остальных команд апплета. Ожидаемые пробелы — в
/// [expectedOptionGaps] (`tool/parity_policy.dart`).
library;

import 'package:virtual_git/src/git_cli.dart';

/// Реализованные длинные опции `git diff`.
const gitDiffParseLongOptions = <GitOption>[
  GitOption('cached'),
  GitOption('staged'),
  GitOption('merge-base'),
  GitOption('exit-code'),
  GitOption('quiet'),
  GitOption('full-index'),
  GitOption('name-only'),
  GitOption('name-status'),
  GitOption('numstat'),
  GitOption('no-patch'),
  GitOption('patch'),
  GitOption('patch-with-stat'),
  GitOption('shortstat'),
  GitOption('stat'),
];

/// Короткие опции `git diff -h`, сопоставленные с длинными выше.
const gitDiffParseShortOptions = <GitOption>[
  GitOption('patch', short: 'p', recordAs: 'patch'),
  GitOption('patch', short: 'u', recordAs: 'patch'),
  GitOption('R', short: 'R'),
];

/// Полный разбор `git diff`.
const gitDiffParseOptions = <GitOption>[
  ...gitDiffParseLongOptions,
  ...gitDiffParseShortOptions,
];

/// Длинные опции `git range-diff` (только то, что меняет [runRangeDiff]).
const gitRangeDiffParseLongOptions = <GitOption>[
  GitOption('creation-factor', valued: true),
  GitOption('left-only'),
  GitOption('right-only'),
  GitOption('exit-code'),
  GitOption('quiet'),
  GitOption('no-patch'),
  GitOption('patch'),
  GitOption('unified', valued: true, optional: true),
];

/// Короткие опции `git range-diff -h`.
const gitRangeDiffParseShortOptions = <GitOption>[
  GitOption('patch', short: 'p', recordAs: 'patch'),
  GitOption('patch', short: 'u', recordAs: 'patch'),
  GitOption('no-patch', short: 's'),
  GitOption('unified', short: 'U', valued: true, optional: true),
];

const gitRangeDiffParseOptions = <GitOption>[
  ...gitRangeDiffParseLongOptions,
  ...gitRangeDiffParseShortOptions,
];
