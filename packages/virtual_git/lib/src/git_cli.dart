/// Разбор argv так, как это делает `git` (parse-options).
///
/// Длинные опции: `--name`, `--name=value`, `--no-name` для флага.
/// Короткие: `-s`, `-svalue`, склейка флагов `-abc`. `--` отдаёт хвост как операнды.
/// Неизвестная опция — код 129 и `error: unknown option`. Нет значения — код 129
/// и `error: option|switch ... requires a value`, без страницы справки: у git её тоже нет.
library;

/// Опция подкоманды. [valued] забирает аргумент, [optional] не трогает следующее слово:
/// значение только из `--name=value` или `-svalue`.
final class GitOption {
  const GitOption(
    this.name, {
    this.short,
    this.valued = false,
    this.optional = false,
    this.missing,
    this.missingExit = 129,

    /// Если задано, в [GitInvocation] попадает этот ключ вместо [name]
    /// (несколько синонимов `-p`/`-u` → одна логическая опция).
    this.recordAs,
  });

  /// Длинное имя без `--`.
  final String name;

  /// Короткая буква без `-`.
  final String? short;

  final bool valued;

  /// См. [GitInvocation.enabled] / [GitInvocation.values].
  final String? recordAs;

  /// Голый `--name` остаётся флагом, значение приходит только приклеенным.
  final bool optional;

  /// Текст ошибки, если значения нет. Иначе стандартная фраза git.
  final String? missing;

  final int missingExit;
}

/// Разобранные аргументы одной подкоманды.
final class GitInvocation {
  const GitInvocation({
    required this.enabled,
    required this.values,
    required this.operands,
    required this.separated,
  });

  final Set<String> enabled;
  final Map<String, List<String>> values;
  final List<String> operands;

  /// В команде был `--`: операнды после него не выглядят как опции.
  final bool separated;

  bool has(String name) => enabled.contains(name);

  /// Последнее значение опции. Пустая строка — опция была без приклеенного текста.
  String? value(String name) {
    final all = values[name];
    if (all == null || all.isEmpty) return null;
    return all.last;
  }

  List<String> valuesOf(String name) => values[name] ?? const [];
}

/// Ошибка разбора: текст уже с переводом строки, код как у git.
final class GitUsage implements Exception {
  const GitUsage(this.message, {this.exitCode = 129});

  final String message;
  final int exitCode;
}

/// Глобальные опции до имени подкоманды: `-C`, `-c`, `--bare`, `--version`, `--help`.
final class GitGlobals {
  const GitGlobals({
    required this.cwd,
    required this.bare,
    required this.version,
    required this.help,
    required this.config,
    required this.args,
  });

  final String cwd;
  final bool bare;
  final bool version;
  final bool help;
  final List<({String key, String value})> config;

  /// Имя команды и её аргументы. Пусто, если команды не было.
  final List<String> args;
}

const gitRootUsage =
    'usage: git [-v | --version] [-h | --help] [-C <path>] [-c <name>=<value>]\n'
    '           [--bare] <command> [<args>]\n';

/// Разбирает префикс до подкоманды. [resolve] склеивает `-C` с текущим каталогом.
GitGlobals parseGitGlobals(
  List<String> args, {
  required String cwd,
  required String Function(String cwd, String path) resolve,
}) {
  var current = cwd;
  var bare = false;
  var version = false;
  var help = false;
  final config = <({String key, String value})>[];
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--') {
      return GitGlobals(
        cwd: current,
        bare: bare,
        version: version,
        help: help,
        config: config,
        args: args.sublist(index + 1),
      );
    }
    if (!arg.startsWith('-') || arg == '-') {
      return GitGlobals(
        cwd: current,
        bare: bare,
        version: version,
        help: help,
        config: config,
        args: args.sublist(index),
      );
    }
    if (arg == '--version' || arg == '-v') {
      version = true;
      continue;
    }
    if (arg == '--help' || arg == '-h') {
      help = true;
      continue;
    }
    if (arg == '--bare') {
      bare = true;
      continue;
    }
    if (arg == '-C' || arg.startsWith('-C')) {
      final inline = arg == '-C' ? null : _slice(arg, 2, arg.length);
      final path = inline ?? _takeNext(args, index, '-C');
      if (inline == null) index++;
      current = resolve(current, path);
      continue;
    }
    if (arg == '-c' || arg.startsWith('-c')) {
      final inline = arg == '-c' ? null : _slice(arg, 2, arg.length);
      final raw = inline ?? _takeNext(args, index, '-c');
      if (inline == null) index++;
      config.add(_configPair(raw));
      continue;
    }
    if (arg.startsWith('--')) {
      throw GitUsage(
        "error: unknown option `${_slice(arg, 2, arg.length)}'\n$gitRootUsage",
      );
    }
    throw GitUsage("error: unknown switch `${_slice(arg, 1, arg.length)}'\n");
  }
  return GitGlobals(
    cwd: current,
    bare: bare,
    version: version,
    help: help,
    config: config,
    args: const [],
  );
}

/// Разбирает аргументы подкоманды. [usage] — одна строка `usage: git ...` для неизвестной опции.
GitInvocation parseGitArgs(
  List<String> args,
  List<GitOption> options, {
  required String usage,
}) {
  String recordKey(GitOption option) => option.recordAs ?? option.name;

  final byLong = <String, GitOption>{
    for (final option in options) option.name: option,
  };
  final byShort = <String, GitOption>{
    for (final option in options)
      if (option.short != null) option.short!: option,
  };
  final enabled = <String>{};
  final values = <String, List<String>>{};
  final operands = <String>[];
  var separated = false;
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (separated || arg == '-' || !arg.startsWith('-')) {
      operands.add(arg);
      continue;
    }
    if (arg == '--') {
      separated = true;
      continue;
    }
    if (arg.startsWith('--')) {
      final body = _slice(arg, 2, arg.length);
      final eq = body.indexOf('=');
      final name = eq < 0 ? body : _slice(body, 0, eq);
      final inline = eq < 0 ? null : _slice(body, eq + 1, body.length);
      final option = byLong[name];
      if (option == null) {
        if (inline == null && name.startsWith('no-')) {
          final base = _slice(name, 3, name.length);
          final positive = byLong[base];
          if (positive != null && !positive.valued) {
            enabled.remove(base);
            continue;
          }
        }
        throw GitUsage("error: unknown option `$name'\n$usage\n");
      }
      if (!option.valued) {
        if (inline != null) {
          throw GitUsage("error: unknown option `$name'\n$usage\n");
        }
        enabled.add(recordKey(option));
        continue;
      }
      final value =
          inline ??
          (option.optional
              ? ''
              : _missingOrNext(args, index, option, long: true));
      if (inline == null && !option.optional) index++;
      _addValue(enabled, values, recordKey(option), value);
      continue;
    }
    final body = _slice(arg, 1, arg.length);
    for (var cursor = 0; cursor < body.length; cursor++) {
      final letter = body[cursor];
      final option = byShort[letter];
      if (option == null) {
        throw GitUsage("error: unknown switch `$letter'\n$usage\n");
      }
      if (!option.valued) {
        enabled.add(recordKey(option));
        continue;
      }
      final rest = _slice(body, cursor + 1, body.length);
      final value = rest.isNotEmpty
          ? rest
          : (option.optional
                ? ''
                : _missingOrNext(args, index, option, long: false));
      if (rest.isEmpty && !option.optional) index++;
      _addValue(enabled, values, recordKey(option), value);
      break;
    }
  }
  return GitInvocation(
    enabled: enabled,
    values: values,
    operands: operands,
    separated: separated,
  );
}

String _missingOrNext(
  List<String> args,
  int index,
  GitOption option, {
  required bool long,
}) {
  if (index + 1 >= args.length) {
    throw GitUsage(
      option.missing ??
          (long
              ? "error: option `${option.name}' requires a value\n"
              : "error: switch `${option.short}' requires a value\n"),
      exitCode: option.missingExit,
    );
  }
  return args[index + 1];
}

void _addValue(
  Set<String> enabled,
  Map<String, List<String>> values,
  String name,
  String value,
) {
  enabled.add(name);
  values.putIfAbsent(name, () => []).add(value);
}

String _takeNext(List<String> args, int index, String flag) {
  if (index + 1 >= args.length) {
    throw GitUsage(
      flag == '-C'
          ? "no directory given for '-C' option\n$gitRootUsage"
          : "error: option `$flag' requires a value\n",
    );
  }
  return args[index + 1];
}

({String key, String value}) _configPair(String raw) {
  final eq = raw.indexOf('=');
  if (eq <= 0) {
    throw GitUsage(
      'error: key does not contain a section: ${_slice(raw, 0, eq < 0 ? raw.length : eq)}\n',
    );
  }
  return (key: _slice(raw, 0, eq), value: _slice(raw, eq + 1, raw.length));
}

String _slice(String text, int start, int end) =>
    String.fromCharCodes(text.codeUnits.getRange(start, end));
