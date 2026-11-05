/// Политика `run_command` поверх `command_shield`.
///
/// Пакет только разбирает строку и никогда её не запускает. Здесь из его
/// разбора собирается жёсткий пол: эскалация и критический риск запрещены,
/// пайп, присваивание и оборванная кавычка требуют подтверждения. Уровень
/// категории, команды и аргумента задаёт профиль и применяется отдельно.
library;

import 'package:command_shield/command_shield.dart';

/// Имена, которые запускают команду от другого пользователя.
///
/// `sudoedit`, `gosu`, `run0` и `please` пакет знает не все как отдельные
/// записи, поэтому запрет держится и на имени файла, и на возможности
/// `privilegeEscalation`.
const _escalationExecutables = {
  'sudo',
  'su',
  'doas',
  'pkexec',
  'runas',
  'sudoedit',
  'gosu',
  'run0',
  'please',
};

/// База знаний щита: штатные плагины пакета и поправки агента.
///
/// Поправки: `sort -o` пишет файл, `date -s` и `hostname` с аргументом меняют
/// систему, `sudoedit` повышает права. Каталог настроек читает ту же базу.
CommandKnowledgeBase agentKnowledgeBase() => _agentKnowledge();

/// Собирает щит с базой знаний агента и политикой [PolicySet].
///
/// Детектор риска базы включён отдельно: в пакете он выключен, а без него
/// `kill 1` выглядит как обычный просмотр процессов.
CommandShield buildAgentCommandShield(List<RegExp> denylist) {
  final knowledge = agentKnowledgeBase();
  return CommandShield(
    defaultSyntax: CommandSyntax.bash,
    analyzer: Analyzer(
      knowledgeBase: knowledge,
      securityAnalyzer: SecurityAnalyzer(
        detectors: [
          ...SecurityAnalyzer.defaultDetectors,
          KnowledgeRiskDetector(knowledgeBase: knowledge),
        ],
      ),
    ),
    policy: PolicySet([
      EscalationCommandPolicy(),
      AgentRiskPolicy(),
      DenylistCommandPolicy(denylist),
      const OperatorCommandPolicy(),
      const ShellStateCommandPolicy(),
      const ParseCommandPolicy(),
      const LengthLimitPolicy(maxLength: 8192),
    ], name: 'agent'),
  );
}

/// Запрещает эскалацию, в том числе через обёртку (`env sudo`, `command sudo`).
///
/// `command -v` только ищет имя и команду не запускает, поэтому цель поиска
/// не считается эскалацией.
class EscalationCommandPolicy extends CommandPolicy {
  /// Создаёт политику с штатным нормализатором имён.
  EscalationCommandPolicy({Normalizer? normalizer})
    : _normalizer = normalizer ?? Normalizer.standard();

  final Normalizer _normalizer;

  @override
  String get name => 'agent-escalation';

  @override
  CommandResult evaluate(CommandAnalysis analysis) {
    if (analysis.canEscalatePrivileges || _namesEscalation(analysis)) {
      return result(
        CommandDecision.deny,
        SecurityLevel.critical,
        'privilege escalation is not allowed',
      );
    }
    return allowResult;
  }

  bool _namesEscalation(CommandAnalysis analysis) {
    for (final invocation in analysis.invocations) {
      if (invocation.executable.isEmpty) continue;
      final executable = _normalizer
          .normalize(invocation.executable)
          .toLowerCase();
      if (_escalationExecutables.contains(executable)) return true;
      if (executable == 'command' &&
          (invocation.arguments.contains('-v') ||
              invocation.arguments.contains('-V'))) {
        continue;
      }
      if (!_wrappers.contains(executable)) continue;
      final wrapped = _wrappedName(invocation.arguments);
      if (wrapped != null && _escalationExecutables.contains(wrapped)) {
        return true;
      }
    }
    return false;
  }

  String? _wrappedName(List<String> arguments) {
    for (final argument in arguments) {
      if (argument.startsWith('-') || argument.contains('=')) continue;
      return _normalizer.normalize(argument).toLowerCase();
    }
    return null;
  }
}

/// Запрещает команды по регулярным выражениям пользователя.
///
/// Это дополнительный слой: обход шаблона кавычками или другим написанием
/// не отменяет критический вердикт [AgentRiskPolicy].
class DenylistCommandPolicy extends CommandPolicy {
  /// Создаёт политику. Пустой список ничего не запрещает.
  DenylistCommandPolicy(this._patterns);

  final List<RegExp> _patterns;

  @override
  String get name => 'denylist';

  @override
  CommandResult evaluate(CommandAnalysis analysis) {
    for (final pattern in _patterns) {
      if (pattern.hasMatch(analysis.raw)) {
        return result(
          CommandDecision.deny,
          SecurityLevel.critical,
          'matches denylist: ${pattern.pattern}',
        );
      }
    }
    return allowResult;
  }
}

/// Переводит средний и высокий риск на подтверждение, критический — в запрет.
///
/// Текст берётся из находки детектора (`rm -rf /`, `curl | bash`), а не из
/// общего «превышен порог»: его видит модель в причине отказа.
class AgentRiskPolicy extends CommandPolicy {
  /// Создаёт политику.
  const AgentRiskPolicy();

  @override
  String get name => 'agent-risk';

  @override
  CommandResult evaluate(CommandAnalysis analysis) {
    if (analysis.findings.isEmpty) return allowResult;
    final top = analysis.findings.first;
    if (!top.level.isAtLeast(SecurityLevel.mediumRisk)) return allowResult;
    final decision = top.level.isAtLeast(SecurityLevel.critical)
        ? CommandDecision.deny
        : CommandDecision.review;
    return CommandResult(
      decision: decision,
      securityLevel: top.level,
      findings: [top],
    );
  }
}

/// Подтверждение для пайпа, редиректа и связки команд.
///
/// У пакета пайп и редирект — низкий риск, и штатная политика их пропускает.
/// Для агента это по-прежнему действие, которое пользователь подтверждает:
/// справа от пайпа может оказаться интерпретатор, редирект пишет файл.
/// Слияние дескрипторов (`2>&1`) детектор сюда не кладёт: файл оно не пишет.
class OperatorCommandPolicy extends CommandPolicy {
  /// Создаёт политику.
  const OperatorCommandPolicy();

  @override
  String get name => 'agent-operator';

  @override
  CommandResult evaluate(CommandAnalysis analysis) {
    final hasOperator = analysis.findings.any(
      (finding) => finding.code == 'dangerous-operator',
    );
    if (!hasOperator && !analysis.raw.contains('\n')) return allowResult;
    return result(
      CommandDecision.review,
      SecurityLevel.lowRisk,
      'pipes, redirects, separators or substitutions',
    );
  }
}

/// Подтверждение для присваивания в параметре и арифметики `((`.
///
/// Пакет видит в `${x:=y}` только чтение переменной. Для оболочки это запись
/// в переменную, то есть смена состояния, и автозапуск здесь неуместен.
/// Форма `${x:-y}` только подставляет значение по умолчанию и не попадает
/// под шаблон.
class ShellStateCommandPolicy extends CommandPolicy {
  /// Создаёт политику.
  const ShellStateCommandPolicy();

  static final _mutation = RegExp(r'\$\{[^}]*(:=|=|\?)|\(\(');

  @override
  String get name => 'agent-shell-state';

  @override
  CommandResult evaluate(CommandAnalysis analysis) {
    if (!_mutation.hasMatch(analysis.raw)) return allowResult;
    return result(
      CommandDecision.review,
      SecurityLevel.mediumRisk,
      'parameter assignment or arithmetic',
    );
  }
}

/// Неавтозапуск, если разбор не уверен в строке.
///
/// Парсеры пакета не бросают исключение: оборванная кавычка — предупреждение,
/// а дерево при этом выглядит как безобидный `ls`. В bash такая строка
/// либо синтаксическая ошибка, либо прячет хвост (`ls "foo; sudo id`).
/// Пока диагностика не пустая, автозапуск закрыт. Сообщения уровня info
/// разбор не ставит под сомнение.
class ParseCommandPolicy extends CommandPolicy {
  /// Создаёт политику.
  const ParseCommandPolicy();

  @override
  String get name => 'agent-parse';

  @override
  CommandResult evaluate(CommandAnalysis analysis) {
    final uncertain = analysis.diagnostics.any(
      (diagnostic) => diagnostic.severity != DiagnosticSeverity.info,
    );
    if (!uncertain) return allowResult;
    return result(
      CommandDecision.review,
      SecurityLevel.mediumRisk,
      'command could not be parsed safely',
    );
  }
}

/// Обёртки, за первым аргументом которых может скрываться другая программа.
const _wrappers = {
  'env',
  'xargs',
  'time',
  'nohup',
  'timeout',
  'watch',
  'exec',
  'builtin',
  'stdbuf',
  'command',
  'nice',
  'busybox',
  'toybox',
};

CommandKnowledgeBase _agentKnowledge() => CommandKnowledgeBase(
  plugins: [
    ListKnowledgePlugin('agent', [
      const CommandKnowledge(
        executable: 'sudoedit',
        category: KnowledgeCategory.shell,
        description: 'Edits a file with raised privileges.',
        baseCapabilities: {CommandCapability.privilegeEscalation},
        wrapper: WrapperSpec(),
      ),
      const CommandKnowledge(
        executable: 'sort',
        category: KnowledgeCategory.filesystem,
        description: 'Sorts lines. -o writes the result to a file.',
        baseCapabilities: {CommandCapability.readFilesystem},
        argumentRules: [
          ArgumentRule(PrefixFlag({'-o', '--output'}), {
            CommandCapability.writeFilesystem,
          }, description: 'sort -o writes sorted lines to a file.'),
        ],
      ),
      const CommandKnowledge(
        executable: 'date',
        category: KnowledgeCategory.filesystem,
        description: 'Prints the date. -s and --set change the system clock.',
        baseCapabilities: {CommandCapability.readFilesystem},
        argumentRules: [
          ArgumentRule(
            ExactFlag({'-s', '--set'}),
            {CommandCapability.systemConfiguration},
            risk: SecurityLevel.highRisk,
            description: 'date -s sets the system clock.',
          ),
        ],
      ),
      CommandKnowledge(
        executable: 'hostname',
        category: KnowledgeCategory.filesystem,
        description: 'Prints the hostname. An argument sets it.',
        baseCapabilities: const {CommandCapability.readFilesystem},
        refine: (args, match) {
          if (args.isEmpty) return;
          match
            ..add(CommandCapability.systemConfiguration)
            ..note('hostname with arguments changes the system name.');
        },
      ),
    ]),
  ],
);
