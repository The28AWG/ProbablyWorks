/// Классификация `run_command` до запуска на хосте.
///
/// Сначала строка проходит [CommandShield]: синтаксис bash, возможности,
/// детекторы и жёсткий пол (эскалация, критическая находка, denylist, пайп,
/// присваивание, оборванная кавычка). Затем [SecurityProfile] называет уровень
/// категории, команды или аргумента. Итог — более строгий из двух.
/// Вложенный текст `eval`, `sh -c` и апплета busybox разбирается отдельно,
/// чтобы `eval sudo` не проскочил как обычный `eval`.
library;

import 'package:command_shield/command_shield.dart';
import 'package:probably_works/agent/policy/agent_command_policy.dart';
import 'package:probably_works/agent/policy/command_catalog.dart';
import 'package:probably_works/agent/policy/command_risk.dart';
import 'package:probably_works/agent/policy/security_profile.dart';

export 'package:probably_works/agent/policy/command_risk.dart';

/// Классификатор `run_command`.
///
/// Denylist пользователя — дополнительный запрет поверх разбора, а не его
/// замена. Кавычки и другое написание обходят регулярное выражение, но не
/// детектор критической команды.
class CommandClassifier {
  /// Собирает классификатор. Некорректное выражение denylist бросает
  /// [FormatException] ещё при создании, а не в момент запуска команды.
  /// [profile] по умолчанию — встроенные уровни.
  CommandClassifier({
    required List<String> denylist,
    this.profile = const SecurityProfile(),
  }) : _catalog = CommandCatalog.instance,
       _shield = buildAgentCommandShield([
         for (final pattern in denylist)
           if (pattern.trim().isNotEmpty) RegExp(pattern),
       ]);

  /// Уровни категорий, команд и аргументов. Жёсткий пол щита они не опускают.
  final SecurityProfile profile;
  final CommandCatalog _catalog;
  final CommandShield _shield;
  static final Normalizer _normalizer = Normalizer.standard();

  /// Сколько уровней `bash -c` / `eval` разбирать вглубь.
  ///
  /// Глубже защита уже не различает новый текст, а рекурсия на копии той же
  /// строки была бы бесконечной. Восемь совпадает с пределом вложенности
  /// `eval` виртуальной оболочки.
  static const _maxInlineDepth = 8;

  static const _shells = {'bash', 'sh', 'zsh', 'dash', 'ksh', 'fish'};
  static const _applets = {'busybox', 'toybox'};

  /// Классифицирует [command]. Пустая строка запрещена.
  CommandClassification classify(String command) =>
      _classify(command, depth: 0);

  CommandClassification _classify(String command, {required int depth}) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      return const CommandClassification(CommandRisk.deny, 'empty command');
    }
    final analysis = _shield.analyze(trimmed);
    var result = _stricter(
      _fromShield(analysis, _shield.validateAnalysis(analysis)),
      _fromProfile(analysis),
    );
    if (depth < _maxInlineDepth) {
      for (final payload in _inlinePayloads(analysis)) {
        if (payload.trim().isEmpty || payload.trim() == trimmed) continue;
        final inner = _classify(payload, depth: depth + 1);
        if (inner.risk.index > result.risk.index) result = inner;
      }
    }
    return result;
  }

  /// Уровень профиля по каждому вызову. Берётся самый строгий.
  ///
  /// Вызов без имени не поднимает уровень: пустую команду отсекает разбор выше.
  CommandClassification _fromProfile(CommandAnalysis analysis) {
    CommandRisk? strongest;
    var executable = '';
    final normalized = analysis.normalizedExecutables;
    var index = 0;
    for (final invocation in analysis.invocations) {
      if (invocation.executable.isEmpty) continue;
      final name = index < normalized.length
          ? normalized[index].toLowerCase()
          : _normalizer.normalize(invocation.executable).toLowerCase();
      index++;
      final level = profile.levelFor(
        executable: name,
        args: invocation.arguments,
        category: _catalog.categoryOf(name),
      );
      if (strongest == null || level.index > strongest.index) {
        strongest = level;
        executable = name;
      }
    }
    final risk = strongest ?? CommandRisk.ask;
    final reason = switch (risk) {
      CommandRisk.auto => 'read-only command',
      CommandRisk.ask => 'command risk requires approval: $executable',
      CommandRisk.deny => 'command risk is set to deny: $executable',
    };
    return CommandClassification(risk, reason);
  }

  CommandClassification _stricter(
    CommandClassification shield,
    CommandClassification profile,
  ) => profile.risk.index > shield.risk.index ? profile : shield;

  CommandClassification _fromShield(
    CommandAnalysis analysis,
    CommandResult verdict,
  ) => CommandClassification(switch (verdict.decision) {
    CommandDecision.allow => CommandRisk.auto,
    CommandDecision.review => CommandRisk.ask,
    CommandDecision.deny => CommandRisk.deny,
  }, _reason(verdict, analysis));

  /// Текст `eval`, `sh -c` и апплета busybox, который надо разобрать отдельно.
  ///
  /// Детектор разрушения не смотрит сквозь `busybox`, а `eval` не объявлен
  /// обёрткой. Без повторного разбора `busybox rm -rf /` и `eval sudo ls`
  /// были бы лишь «запуском кода» и в режиме авто-подтверждения выполнились.
  List<String> _inlinePayloads(CommandAnalysis analysis) {
    final payloads = <String>[];
    final normalized = analysis.normalizedExecutables;
    var index = 0;
    for (final invocation in analysis.invocations) {
      if (invocation.executable.isEmpty) continue;
      final executable = index < normalized.length
          ? normalized[index].toLowerCase()
          : _normalizer.normalize(invocation.executable).toLowerCase();
      index++;
      if (executable == 'eval') {
        if (invocation.arguments.isNotEmpty) {
          payloads.add(invocation.arguments.join(' '));
        }
      } else if (_shells.contains(executable)) {
        final script = _argumentAfter(invocation.arguments, const {
          '-c',
          '--command',
        });
        if (script != null && script.isNotEmpty) payloads.add(script);
      } else if (_applets.contains(executable) &&
          invocation.arguments.isNotEmpty) {
        payloads.add(invocation.arguments.join(' '));
      }
    }
    return payloads;
  }

  String? _argumentAfter(List<String> arguments, Set<String> flags) {
    for (var i = 0; i < arguments.length - 1; i++) {
      if (flags.contains(arguments[i])) return arguments[i + 1];
    }
    return null;
  }

  String _reason(CommandResult verdict, CommandAnalysis analysis) {
    if (verdict.decision == CommandDecision.allow) return 'read-only command';
    for (final finding in verdict.findings) {
      if (finding.code == 'agent-escalation') {
        return 'privilege escalation is not allowed';
      }
    }
    if (verdict.decision == CommandDecision.deny) {
      for (final finding in analysis.findings) {
        if (finding.level == SecurityLevel.critical) return finding.message;
      }
      for (final finding in verdict.findings) {
        if (finding.code == 'denylist') return finding.message;
      }
    }
    for (final finding in verdict.findings) {
      if (finding.code == 'agent-parse' ||
          finding.code == 'agent-shell-state' ||
          finding.code == 'agent-operator') {
        return finding.message;
      }
    }
    for (final finding in analysis.findings) {
      if (finding.level.isAtLeast(SecurityLevel.mediumRisk)) {
        return finding.message;
      }
    }
    for (final finding in verdict.findings) {
      if (finding.code == 'agent-effect') return finding.message;
    }
    if (verdict.findings.isNotEmpty) return verdict.findings.first.message;
    return verdict.decision == CommandDecision.deny
        ? 'denied by command policy'
        : 'needs approval';
  }
}
