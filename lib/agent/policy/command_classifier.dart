import 'package:probably_works/core/util/char_substring.dart';

enum CommandRisk { auto, ask, deny }

class CommandClassification {
  const CommandClassification(this.risk, this.reason);

  final CommandRisk risk;
  final String reason;
}

/// Классификатор `run_command`. Граница безопасности — Ask по умолчанию;
/// denylist — только UX-страховка (его легко обойти через eval/base64).
class CommandClassifier {
  CommandClassifier({required List<String> denylist})
    : _denylist = [
        for (final pattern in denylist)
          if (pattern.trim().isNotEmpty) RegExp(pattern),
      ];

  final List<RegExp> _denylist;

  /// Эскалация привилегий запрещена всегда (см. README-план: «пользователь выбирает Host с нужным доступом»).
  static const escalationBinaries = {
    'sudo',
    'su',
    'doas',
    'pkexec',
    'runas',
    'sudoedit',
  };

  /// Read-only бинарники без подстановок: Auto, если нет пайпов/редиректов/`;`/`&&`.
  static const readOnlyBinaries = {
    'ls',
    'cat',
    'pwd',
    'which',
    'uname',
    'df',
    'du',
    'ps',
    'head',
    'tail',
    'wc',
    'stat',
    'file',
    'free',
    'uptime',
    'whoami',
    'id',
    'date',
    'hostname',
    'printenv',
    'echo',
    'tree',
    'nproc',
    'lscpu',
    'grep',
    'rg',
    'sort',
    'uniq',
    'basename',
    'dirname',
    'realpath',
    'readlink',
    'md5sum',
    'sha256sum',
  };

  static const readOnlyGitSubcommands = {
    'status',
    'diff',
    'log',
    'show',
    'branch',
    'rev-parse',
    'remote',
    'ls-files',
  };

  /// Кроме пайпов и подстановок команд, Ask получают присваивания в параметрах
  /// (`${x:=}`, `${x=}`, `${x:?}`) и арифметика `((...))`: они меняют состояние оболочки.
  static final _unsafeSyntax = RegExp(
    r'[|;&<>`\n]|\$\(|\$\{[^}]*(:=|=|\?)|\(\(',
  );

  CommandClassification classify(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      return const CommandClassification(CommandRisk.deny, 'empty command');
    }
    final tokens = _tokens(trimmed);
    for (final token in tokens) {
      if (escalationBinaries.contains(_basename(token))) {
        return const CommandClassification(
          CommandRisk.deny,
          'privilege escalation is not allowed',
        );
      }
    }
    for (final pattern in _denylist) {
      if (pattern.hasMatch(trimmed)) {
        return CommandClassification(
          CommandRisk.deny,
          'matches denylist: ${pattern.pattern}',
        );
      }
    }
    if (_unsafeSyntax.hasMatch(trimmed)) {
      return const CommandClassification(
        CommandRisk.ask,
        'pipes, redirects, separators or substitutions',
      );
    }
    final first = _basename(tokens.first);
    if (first == 'git') {
      final sub = tokens.length > 1 ? tokens[1] : '';
      return readOnlyGitSubcommands.contains(sub)
          ? const CommandClassification(CommandRisk.auto, 'read-only git')
          : const CommandClassification(CommandRisk.ask, 'git write operation');
    }
    if (readOnlyBinaries.contains(first)) {
      if (_writesDespiteReadOnly(first, tokens)) {
        return CommandClassification(
          CommandRisk.ask,
          'read-only command with a writing flag: $first',
        );
      }
      return const CommandClassification(CommandRisk.auto, 'read-only command');
    }
    return CommandClassification(
      CommandRisk.ask,
      'unknown or write command: $first',
    );
  }

  /// Флаги, которые пишут в файл или меняют систему, хотя команда есть в списке чтения.
  static bool _writesDespiteReadOnly(String command, List<String> tokens) {
    if (command == 'sort') {
      return tokens.any((token) => token == '-o' || token.startsWith('-o'));
    }
    if (command == 'date') {
      return tokens.any((token) => token == '-s' || token == '--set');
    }
    if (command == 'hostname') return tokens.length > 1;
    if (command == 'printf') return tokens.contains('-v');
    return false;
  }

  static List<String> _tokens(String command) => command
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .map(_unquote)
      .toList();

  static String _unquote(String token) => token.replaceAll(RegExp('["\']'), '');

  static String _basename(String token) {
    final index = token.lastIndexOf('/');
    return index == -1 ? token : charFrom(token, index + 1);
  }
}
