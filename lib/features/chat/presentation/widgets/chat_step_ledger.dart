import 'dart:math' as math;

import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/router/app_router.gr.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/file_change.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_motion.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_viewport.dart';
import 'package:probably_works/features/chat/presentation/widgets/step_block.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/core/util/ansi_text.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/core/util/workspace_path.dart';
import 'package:pw_agent/host/host_terminal.dart';
import 'package:pw_agent/host/read_file_output.dart';

part 'chat_step_ledger_thought.dart';
part 'chat_step_ledger_step.dart';
part 'chat_step_ledger_heading.dart';

/// Шаг журнала ответа: рассуждения модели или запуск команды. В группе идут в порядке появления.
sealed class LedgerStep {
  const LedgerStep();

  String get id;
}

/// Рассуждения модели. [live] — шаг ещё идёт, текст дописывается в стриме.
final class ThoughtStep extends LedgerStep {
  const ThoughtStep({required this.id, required this.text, this.live = false});

  @override
  final String id;
  final String text;
  final bool live;
}

/// Запуск команды.
final class RunStep extends LedgerStep {
  const RunStep(this.run);

  final ToolRun run;

  @override
  String get id => run.id;
}

/// Журнал шагов одного участка ответа ассистента: рассуждения модели и команды, которые она выполнила.
///
/// Один шаг выводится просто строкой: заголовок группы без него лишний шаг до текста. Несколько шагов
/// сворачиваются в группу с итогом в одну строку. Группа раскрывается сама, пока есть активные шаги
/// или шаги, требующие внимания (ожидание, ошибка). Ошибки никогда не прячутся в свёрнутом виде.
/// Раскрытие, переход между одиночным шагом и группой и смена статуса идут плавно.
class ChatStepLedger extends StatefulWidget {
  const ChatStepLedger({
    required this.steps,
    required this.live,
    this.terminalFor,
    this.expandThoughts = false,
    this.expandTools = false,
    this.expandWhileActive = true,
    this.workspace,
    this.windows = false,
    super.key,
  });

  final List<LedgerStep> steps;
  final Map<String, String> live;

  /// Терминал активного запуска по его id; `null`, если запуск не выполняется в PTY.
  final HostTerminal? Function(String runId)? terminalFor;

  /// Рассуждения и вывод команд раскрыты сразу. Журнал при этом тоже открыт.
  final bool expandThoughts;
  final bool expandTools;

  /// Группа раскрывается сама, пока её шаги выполняются или рассуждают. Выключено: остаётся свёрнутой.
  final bool expandWhileActive;

  /// Рабочая папка проекта. Путь файла внутри неё в заголовке заменяется именем файла.
  /// Null — папки нет, и дом проектом не считается: путь остаётся полным.
  final String? workspace;

  /// Регистр путей на хосте не важен. Нужен, чтобы `C:\Repo` и `c:/repo` были одной папкой.
  final bool windows;

  @override
  State<ChatStepLedger> createState() => _ChatStepLedgerState();
}

class _ChatStepLedgerState extends State<ChatStepLedger>
    with AutomaticKeepAliveClientMixin<ChatStepLedger> {
  /// Выбор пользователя; `null` — раскрытие определяется состоянием шагов.
  bool? _userExpanded;

  /// Выбор пользователя нельзя потерять, когда группа уходит за край ленты: держим элемент живым.
  @override
  bool get wantKeepAlive => _userExpanded != null;

  void _toggleGroupExpanded(bool expanded) {
    setState(() => _userExpanded = !expanded);
    updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final steps = widget.steps;
    // Один шаг и группа строятся одинаково: иначе при появлении второго шага строки пересоздаются
    // и теряют состояние (раскрытие, прокрутку). Меняется только заголовок и отступ.
    final grouped = steps.length > 1;

    var active = 0;
    var failed = 0;
    var attention = false;
    var done = 0;
    for (final step in steps) {
      switch (step) {
        case ThoughtStep(:final live):
          if (live) {
            active++;
          } else {
            done++;
          }
        case RunStep(:final run):
          if (run.isActive || run.status == ToolRunStatus.backgroundRunning) {
            active++;
          }
          if (_isFailure(run)) failed++;
          if (_needsAttention(run)) attention = true;
          if (run.status == ToolRunStatus.done) done++;
      }
    }

    final revealAll = widget.expandThoughts || widget.expandTools;
    final autoExpand =
        revealAll ||
        (widget.expandWhileActive && active > 0) ||
        attention ||
        failed > 0;
    final expanded = !grouped || (_userExpanded ?? autoExpand);
    final tone = failed > 0
        ? AppTone.danger
        : active > 0
        ? AppTone.progress
        : attention
        ? AppTone.waiting
        : AppTone.success;
    final title = active > 0
        ? l10n.stepsGroupActive(done, steps.length)
        : l10n.stepsGroupDone(steps.length);
    final duration = _groupDuration(steps);

    // Рассуждения различаем номером среди рассуждений, а не id: пока оно стримится, id другой.
    final rows = <Widget>[];
    var thoughts = 0;
    for (final step in steps) {
      final slot = switch (step) {
        ThoughtStep() => 'thought#${thoughts++}',
        RunStep(:final run) => run.id,
      };
      rows.add(
        _LedgerStepRow(
          key: ValueKey(slot),
          step: step,
          live: widget.live,
          terminalFor: widget.terminalFor,
          expandThoughts: widget.expandThoughts,
          expandTools: widget.expandTools,
          inGroup: grouped,
          workspace: widget.workspace,
          windows: widget.windows,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: StepBlock(
        kind: StepKind.group,
        accent: toneColors(context, tone).foreground,
        expanded: expanded,
        showHeader: grouped,
        onToggle: grouped ? () => _toggleGroupExpanded(expanded) : null,
        header: (palette) => _GroupHeading(
          title: failed > 0
              ? '$title · ${l10n.stepsGroupFailed(failed)}'
              : title,
          titleColor: palette.text,
          duration: duration == null
              ? null
              : l10n.runDuration(duration.inSeconds),
          durationColor: palette.muted,
          accent: palette.accent,
          icon: _groupIcon(tone),
          expanded: expanded,
        ),
        body: (palette, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        ),
      ),
    );
  }

  static IconData _groupIcon(AppTone tone) => switch (tone) {
    AppTone.danger => Icons.error_outline,
    AppTone.progress => Icons.more_horiz,
    AppTone.waiting => Icons.hourglass_empty,
    _ => Icons.check_circle_outline,
  };

  static bool _isFailure(ToolRun run) => switch (run.status) {
    ToolRunStatus.failed ||
    ToolRunStatus.timedOut ||
    ToolRunStatus.connectionLost ||
    ToolRunStatus.spawnFailed => true,
    _ => false,
  };

  static bool _needsAttention(ToolRun run) => switch (run.status) {
    ToolRunStatus.waitingApproval ||
    ToolRunStatus.waitingUser ||
    ToolRunStatus.denied ||
    ToolRunStatus.interrupted => true,
    _ => _isFailure(run),
  };

  /// Общее время группы команд: от первого запуска до последнего завершения (или до текущего момента).
  static Duration? _groupDuration(List<LedgerStep> steps) {
    final runs = [
      for (final step in steps)
        if (step case RunStep(:final run)) run,
    ];
    if (runs.isEmpty) return null;
    final start = runs
        .map((r) => r.startedAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    DateTime? end;
    for (final run in runs) {
      final finished = run.finishedAt;
      if (finished == null) {
        end = DateTime.now();
        break;
      }
      if (end == null || finished.isAfter(end)) end = finished;
    }
    return end?.difference(start);
  }
}

class _LedgerStepRow extends StatelessWidget {
  const _LedgerStepRow({
    required this.step,
    required this.live,
    required this.expandThoughts,
    required this.expandTools,
    required this.inGroup,
    this.terminalFor,
    this.workspace,
    this.windows = false,
    super.key,
  });

  final LedgerStep step;
  final Map<String, String> live;
  final HostTerminal? Function(String runId)? terminalFor;
  final bool expandThoughts;
  final bool expandTools;
  final bool inGroup;
  final String? workspace;
  final bool windows;

  @override
  Widget build(BuildContext context) => switch (step) {
    ThoughtStep(:final text, live: final streaming) => _ThoughtRow(
      text: text,
      live: streaming,
      expandedByDefault: expandThoughts,
      inGroup: inGroup,
    ),
    RunStep(:final run) => _StepRow(
      key: ValueKey(run.id),
      run: run,
      live: live[run.id],
      terminal: terminalFor?.call(run.id),
      expandedByDefault: expandTools,
      inGroup: inGroup,
      workspace: workspace,
      windows: windows,
    ),
  };
}
