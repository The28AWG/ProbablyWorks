import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/util/ansi_text.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_motion.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_viewport.dart';
import 'package:probably_works/features/chat/presentation/widgets/step_block.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/host/read_file_output.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

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
    final theme = Theme.of(context);
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
        header: (palette) => Row(
          children: [
            Icon(_groupIcon(tone), size: 16, color: palette.accent),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                failed > 0
                    ? '$title · ${l10n.stepsGroupFailed(failed)}'
                    : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: palette.text,
                ),
              ),
            ),
            if (duration != null) ...[
              const SizedBox(width: AppSpacing.sm),
              Text(
                l10n.runDuration(duration.inSeconds),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: palette.muted,
                ),
              ),
            ],
            const SizedBox(width: AppSpacing.xs),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: AppDurations.fast,
              curve: Curves.easeOutCubic,
              child: Icon(Icons.expand_more, size: 18, color: palette.muted),
            ),
          ],
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
    super.key,
  });

  final LedgerStep step;
  final Map<String, String> live;
  final HostTerminal? Function(String runId)? terminalFor;
  final bool expandThoughts;
  final bool expandTools;
  final bool inGroup;

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
    ),
  };
}

/// Строка рассуждений: первая строка текста, раскрывается до полного текста по нажатию.
/// Пока шаг идёт, первая строка обновляется, а раскрытый текст следует за новым куском, если читатель внизу.
class _ThoughtRow extends StatefulWidget {
  const _ThoughtRow({
    required this.text,
    required this.live,
    required this.inGroup,
    this.expandedByDefault = false,
  });

  final String text;
  final bool live;
  final bool inGroup;

  /// Раскрыто, пока пользователь сам не переключил строку.
  final bool expandedByDefault;

  @override
  State<_ThoughtRow> createState() => _ThoughtRowState();
}

class _ThoughtRowState extends State<_ThoughtRow>
    with AutomaticKeepAliveClientMixin<_ThoughtRow> {
  /// Выбор пользователя; `null` — раскрытие задаёт настройка. По умолчанию рассуждение свёрнуто, в том числе пока стримится.
  bool? _userExpanded;

  bool get _expanded => _userExpanded ?? widget.expandedByDefault;

  final _scroll = ScrollController();

  /// Насколько близко к концу текста считаем, что читатель «внизу».
  static const _followSlack = 24.0;

  @override
  bool get wantKeepAlive => _userExpanded != null;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ThoughtRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Следуем за текстом, только если читатель и так внизу: иначе он не сможет прочитать предыдущее.
    final following =
        !_scroll.hasClients || _scroll.position.extentAfter < _followSlack;
    if (widget.live && widget.text != oldWidget.text && following) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final text = widget.text.trim();
    final canExpand = text.isNotEmpty;
    final summary = _firstLine(text);
    final tone = widget.live
        ? toneColors(context, AppTone.progress).foreground
        : theme.colorScheme.onSurfaceVariant;

    return StepBlock(
      kind: StepKind.thought,
      inGroup: widget.inGroup,
      accent: tone,
      expanded: _expanded && canExpand,
      onToggle: canExpand
          ? () {
              setState(() => _userExpanded = !_expanded);
              updateKeepAlive();
            }
          : null,
      canFullHeight: canExpand,
      header: (palette) => Row(
        children: [
          Icon(Icons.psychology_outlined, size: 16, color: palette.accent),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              summary.isEmpty ? l10n.statusThinking : summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: palette.text),
            ),
          ),
          if (canExpand)
            AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: AppDurations.fast,
              curve: Curves.easeOutCubic,
              child: Icon(Icons.expand_more, size: 18, color: palette.muted),
            ),
        ],
      ),
      body: (palette, fullHeight) => _ThoughtText(
        text: text,
        color: palette.muted,
        fullHeight: fullHeight,
        scroll: _scroll,
      ),
    );
  }

  static String _firstLine(String text) {
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }
}

/// Текст рассуждения в теле блока. Полная высота: без внутреннего скролла. Иначе лимит 220 со скроллом.
class _ThoughtText extends StatelessWidget {
  const _ThoughtText({
    required this.text,
    required this.color,
    required this.fullHeight,
    required this.scroll,
  });

  final String text;
  final Color color;
  final bool fullHeight;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final content = SelectableText(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
    );
    if (fullHeight) return content;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SingleChildScrollView(controller: scroll, child: content),
    );
  }
}

/// Одна строка журнала: статус текстом, команда в моно-шрифте, вывод раскрывается по нажатию.
class _StepRow extends StatefulWidget {
  const _StepRow({
    required this.run,
    required this.live,
    required this.inGroup,
    this.terminal,
    this.expandedByDefault = false,
    super.key,
  });

  final ToolRun run;
  final String? live;
  final HostTerminal? terminal;
  final bool inGroup;

  /// Вывод раскрыт, пока пользователь сам не переключил строку.
  final bool expandedByDefault;

  @override
  State<_StepRow> createState() => _StepRowState();
}

class _StepRowState extends State<_StepRow>
    with AutomaticKeepAliveClientMixin<_StepRow> {
  /// Выбор пользователя; `null` — раскрытие задаёт настройка. По умолчанию команда свёрнута, в том числе во время выполнения.
  bool? _userExpanded;

  /// Текст вывода для кнопки копирования в заголовке.
  final _output = CommandOutputController();

  /// Исходный текст, из которого получен [_parsed]: разбор не повторяется при каждой перерисовке.
  String? _parsedFrom;

  /// Разобранный вывод read_file; `null`, если инструмент другой или вывод не в формате read_file.
  ReadFileOutput? _parsed;

  bool get _expanded => _userExpanded ?? widget.expandedByDefault;

  /// Строку держим живой, пока пользователь её переключал: её выбор нельзя потерять при прокрутке.
  @override
  bool get wantKeepAlive => _userExpanded != null;

  /// Разбор вывода read_file. Для других инструментов всегда `null`.
  ReadFileOutput? _readFileOf(String output) {
    if (widget.run.toolName != ToolNames.readFile) return null;
    if (output != _parsedFrom) {
      _parsedFrom = output;
      _parsed = parseReadFileOutput(output);
    }
    return _parsed;
  }

  /// Текст для копирования. Для read_file копируется содержимое без номеров строк,
  /// для нераспознанного вывода — текст терминала, как раньше.
  String _copyText() => switch (_parsed) {
    ReadFileText(:final lines) => [
      for (final line in lines) plainTerminalText(line.text),
    ].join('\n'),
    null => _output.text,
    _ => widget.run.outputText ?? '',
  };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final run = widget.run;
    final output = widget.live ?? run.outputText ?? '';
    final readFile = _readFileOf(output);
    final active =
        run.isActive || run.status == ToolRunStatus.backgroundRunning;
    final visual = _visualOf(run, l10n);
    final finishedAt = run.finishedAt;
    // Диапазон показанных строк read_file заменяет служебный заголовок вывода: он уже в видах ReadFileView.
    final range = switch (readFile) {
      ReadFileText(:final lines, :final totalLines) when lines.isNotEmpty =>
        l10n.readFileLinesRange(
          lines.first.number,
          lines.last.number,
          totalLines,
        ),
      _ => null,
    };
    final meta = [
      ?range,
      if (finishedAt != null)
        l10n.runDuration(finishedAt.difference(run.startedAt).inSeconds),
    ];
    // Активный шаг с PTY показывает терминал сразу, даже до первого байта вывода.
    final terminal = active ? widget.terminal : null;
    final canExpand = output.isNotEmpty || terminal != null;
    final tone = toneColors(context, visual.tone).foreground;
    final showStop = active && run.status != ToolRunStatus.waitingApproval;
    // Вывод на всю высоту ограничен видимой областью ленты (окно минус заголовок и композер).
    // Вне ленты такой области нет, и предела нет совсем.
    final viewport = ChatViewport.maybeOf(context) ?? double.infinity;
    final collapsedHeight = active ? 320.0 : 220.0;

    return StepBlock(
      kind: StepKind.command,
      inGroup: widget.inGroup,
      accent: tone,
      expanded: _expanded && canExpand,
      onToggle: canExpand
          ? () {
              setState(() => _userExpanded = !_expanded);
              updateKeepAlive();
            }
          : null,
      // Высота живого PTY задаёт размер терминала, поэтому у выполняющейся команды её не снимаем.
      canFullHeight: canExpand && !active,
      trailing: (palette) => CopyButton(
        key: const ValueKey('step-copy'),
        textOf: _copyText,
        color: palette.muted,
        size: 24,
      ),
      header: (palette) => Row(
        children: [
          ChatMorph(
            child: Icon(
              visual.icon,
              key: ValueKey(visual.icon),
              size: 16,
              color: tone,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              run.command ?? run.toolName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppTheme.monoFamily,
                fontSize: 13,
                color: palette.text,
              ),
            ),
          ),
          ChatMorph(
            child: meta.isEmpty
                ? const SizedBox.shrink(key: ValueKey('no-meta'))
                : Row(
                    key: ValueKey(meta.join(' · ')),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        meta.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: palette.muted,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                  ),
          ),
          ChatMorph(
            child: run.background
                ? Row(
                    key: const ValueKey('background'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.runBackgroundBadge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: palette.muted,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                  )
                : const SizedBox.shrink(key: ValueKey('no-background')),
          ),
          ChatMorph(
            child: Text(
              visual.label,
              key: ValueKey(visual.label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(color: tone),
            ),
          ),
          ChatMorph(
            child: showStop
                ? IconButton(
                    key: const ValueKey('stop'),
                    tooltip: l10n.runStop,
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    color: palette.text,
                    icon: const Icon(Icons.stop_circle_outlined),
                    onPressed: () => context.read<ChatBloc>().add(
                      ChatRunStopRequested(run.id),
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('no-stop')),
          ),
          ChatMorph(
            child: canExpand
                ? AnimatedRotation(
                    key: const ValueKey('chevron'),
                    turns: _expanded ? 0.5 : 0,
                    duration: AppDurations.fast,
                    curve: Curves.easeOutCubic,
                    child: Icon(
                      Icons.expand_more,
                      size: 18,
                      color: palette.muted,
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey('no-chevron')),
          ),
        ],
      ),
      body: (palette, fullHeight) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Распознанный вывод read_file показываем видом с номерами строк. Остальное — терминалом, как раньше.
          if (readFile != null)
            ReadFileView(
              output: readFile,
              maxHeight: fullHeight && !active ? viewport : collapsedHeight,
            )
          else
            CommandOutput(
              controller: _output,
              text: output,
              command: run.command,
              exitCode: run.exitCode,
              active: active,
              terminal: terminal,
              maxHeight: fullHeight && !active ? viewport : collapsedHeight,
            ),
          if (run.outputTruncated) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              l10n.runOutputTruncated,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: palette.muted),
            ),
          ],
        ],
      ),
    );
  }

  static ({AppTone tone, IconData icon, String label}) _visualOf(
    ToolRun run,
    AppLocalizations l10n,
  ) => switch (run.status) {
    ToolRunStatus.running => (
      tone: AppTone.progress,
      icon: Icons.terminal,
      label: l10n.runStatusRunning,
    ),
    ToolRunStatus.backgroundRunning => (
      tone: AppTone.progress,
      icon: Icons.sync,
      label: l10n.runStatusBackground,
    ),
    ToolRunStatus.waitingApproval => (
      tone: AppTone.waiting,
      icon: Icons.lock_clock_outlined,
      label: l10n.runStatusWaitingApproval,
    ),
    ToolRunStatus.waitingUser => (
      tone: AppTone.waiting,
      icon: Icons.help_outline,
      label: l10n.runStatusWaitingUser,
    ),
    ToolRunStatus.done => (
      tone: AppTone.success,
      icon: Icons.check_circle_outline,
      label: l10n.runStatusDone,
    ),
    ToolRunStatus.denied => (
      tone: AppTone.warning,
      icon: Icons.block,
      label: l10n.runStatusDenied,
    ),
    ToolRunStatus.timedOut => (
      tone: AppTone.warning,
      icon: Icons.timer_off_outlined,
      label: l10n.runStatusTimedOut,
    ),
    ToolRunStatus.interrupted => (
      tone: AppTone.warning,
      icon: Icons.pause_circle_outline,
      label: l10n.runStatusInterrupted,
    ),
    ToolRunStatus.failed => (
      tone: AppTone.danger,
      icon: Icons.error_outline,
      label: l10n.runStatusFailed,
    ),
    ToolRunStatus.connectionLost => (
      tone: AppTone.danger,
      icon: Icons.link_off,
      label: l10n.runStatusConnectionLost,
    ),
    ToolRunStatus.spawnFailed => (
      tone: AppTone.danger,
      icon: Icons.error_outline,
      label: l10n.runStatusSpawnFailed,
    ),
  };
}
