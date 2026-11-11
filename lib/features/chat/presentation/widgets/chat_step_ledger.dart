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

/// Одна строка журнала: статус, команда или файл, содержимое раскрывается по нажатию.
///
/// `write_file` показывается как новый файл git (все строки добавлены), `edit_file` — как unified diff
/// фрагмента. Успешная запись ничего не печатает, поэтому тело берётся из аргументов, а не из вывода.
/// `read_file` остаётся видом с номерами строк, остальные инструменты — терминалом.
class _StepRow extends StatefulWidget {
  const _StepRow({
    required this.run,
    required this.live,
    required this.inGroup,
    this.terminal,
    this.expandedByDefault = false,
    this.workspace,
    this.windows = false,
    super.key,
  });

  final ToolRun run;
  final String? live;
  final HostTerminal? terminal;
  final bool inGroup;

  /// Вывод раскрыт, пока пользователь сам не переключил строку.
  final bool expandedByDefault;

  /// Рабочая папка проекта. См. [ChatStepLedger.workspace].
  final String? workspace;

  /// См. [ChatStepLedger.windows].
  final bool windows;

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

  static final _subagentRef = RegExp(r'subagent started:\s*([0-9a-fA-F-]+)');

  String? _subagentIdOf(ToolRun run) {
    if (run.toolName != ToolNames.delegateTask) return null;
    return _subagentRef.firstMatch(run.outputText ?? '')?.group(1);
  }

  /// Разобранный вывод read_file; `null`, если инструмент другой или вывод не в формате read_file.
  ReadFileOutput? _parsed;

  /// Разобранное изменение файла. Ключ — аргументы и команда: путь в заголовке берётся из команды.
  FileChange? _change;
  String? _changeArgs;
  String? _changeCommand;

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

  /// Запись или правка файла по аргументам запуска. Для остальных инструментов `null`.
  FileChange? _fileChangeOf(ToolRun run) {
    if (run.toolName != ToolNames.writeFile &&
        run.toolName != ToolNames.editFile &&
        run.toolName != ToolNames.applyPatch) {
      return null;
    }
    if (run.argsJson != _changeArgs || run.command != _changeCommand) {
      _changeArgs = run.argsJson;
      _changeCommand = run.command;
      _change = fileChangeOf(run);
    }
    return _change;
  }

  /// Текст для копирования. Для нового файла — содержимое, для правки — unified diff,
  /// для read_file — текст без номеров строк, иначе текст терминала.
  String _copyText() {
    final change = _change;
    if (change != null) return change.copyText;
    return switch (_parsed) {
      ReadFileText(:final lines) => [
        for (final line in lines) plainTerminalText(line.text),
      ].join('\n'),
      null => _output.text,
      _ => widget.run.outputText ?? '',
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final run = widget.run;
    final subagentId = _subagentIdOf(run);
    final output = widget.live ?? run.outputText ?? '';
    final readFile = _readFileOf(output);
    final change = _fileChangeOf(run);
    final note = plainTerminalText(output).trim();
    final failed = _ChatStepLedgerState._isFailure(run);
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
    final canExpand = change != null || output.isNotEmpty || terminal != null;
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
      // У записи файла нет живого PTY, высоту можно снять и пока запись идёт.
      // У команды высота задаёт размер терминала, поэтому у выполняющейся её не снимаем.
      canFullHeight: canExpand && (change != null || !active),
      trailing: (palette) => subagentId == null
          ? CopyButton(
              key: const ValueKey('step-copy'),
              textOf: _copyText,
              color: palette.muted,
              size: 24,
            )
          : IconButton(
              key: const ValueKey('open-subagent'),
              tooltip: l10n.subagentOpen,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 24, height: 24),
              iconSize: 18,
              color: palette.text,
              onPressed: () =>
                  context.router.push(ChatRoute(chatId: subagentId)),
              icon: const Icon(Icons.open_in_new),
            ),
      header: (palette) => Row(
        children: [
          ChatMorph(
            child: Tooltip(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              richMessage: TextSpan(
                children: [
                  TextSpan(
                    text: visual.label,
                    style: theme.textTheme.labelMedium?.copyWith(color: tone),
                  ),
                ],
              ),
              child: Icon(
                visual.icon,
                key: ValueKey(visual.icon),
                size: 16,
                color: tone,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: _StepHeading(
              title: _stepTitle(
                run,
                change,
                workspace: widget.workspace,
                windows: widget.windows,
              ),
              color: palette.text,
              change: change,
              meta: meta.isEmpty ? null : meta.join(' · '),
              metaColor: palette.muted,
              background: run.background ? l10n.runBackgroundBadge : null,
            ),
          ),
          ChatMorph(
            child: showStop
                ? IconButton(
                    key: const ValueKey('stop'),
                    tooltip: l10n.runStop,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 24,
                      height: 24,
                    ),
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
      body: (palette, fullHeight) => _StepOutput(
        palette: palette,
        fullHeight: fullHeight,
        change: change,
        readFile: readFile,
        output: output,
        note: note,
        failed: failed,
        run: run,
        active: active,
        terminal: terminal,
        controller: _output,
        viewport: viewport,
        collapsedHeight: collapsedHeight,
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

/// Тело шага: изменение файла, чтение файла или терминал команды.
class _StepOutput extends StatelessWidget {
  const _StepOutput({
    required this.palette,
    required this.fullHeight,
    required this.change,
    required this.readFile,
    required this.output,
    required this.note,
    required this.failed,
    required this.run,
    required this.active,
    required this.terminal,
    required this.controller,
    required this.viewport,
    required this.collapsedHeight,
  });

  final StepPalette palette;
  final bool fullHeight;
  final FileChange? change;
  final ReadFileOutput? readFile;
  final String output;
  final String note;
  final bool failed;
  final ToolRun run;
  final bool active;
  final HostTerminal? terminal;
  final CommandOutputController controller;
  final double viewport;
  final double collapsedHeight;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final file = change;
    final parsed = readFile;
    // У записи файла нет живого PTY, поэтому полная высота доступна и во время записи.
    final limit = fullHeight && (file != null || !active)
        ? viewport
        : collapsedHeight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (file != null)
          FileChangeView(change: file, maxHeight: limit)
        else if (parsed != null)
          ReadFileView(output: parsed, maxHeight: limit)
        else
          CommandOutput(
            controller: controller,
            text: output,
            command: run.command,
            exitCode: run.exitCode,
            active: active,
            terminal: terminal,
            maxHeight: limit,
          ),
        if (file != null && note.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            note,
            style: theme.textTheme.bodySmall?.copyWith(
              color: failed
                  ? toneColors(context, AppTone.danger).foreground
                  : palette.muted,
            ),
          ),
        ],
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
    );
  }
}

/// Заголовок шага. У файловых операций перед путём стоит глагол:
/// `read path`, `write path`, `edit path`, `delete path`, `move from → to`, `mkdir path`.
///
/// Путь внутри [workspace] заменяется именем файла. У read, delete, mkdir и stat
/// путь берётся из команды: у этих инструментов нет [FileChange].
String _stepTitle(
  ToolRun run,
  FileChange? change, {
  String? workspace,
  bool windows = false,
}) {
  final file = change;
  if (file != null && file.path.isNotEmpty) {
    final verb = switch (file.kind) {
      FileChangeKind.created => 'write',
      FileChangeKind.edited =>
        run.toolName == ToolNames.applyPatch ? 'patch' : 'edit',
    };
    final label = projectFileLabel(
      file.path,
      workspace: workspace,
      windows: windows,
    );
    return '$verb $label';
  }
  final command = run.command;
  if (command == null) return run.toolName;
  String label(String path) =>
      projectFileLabel(path, workspace: workspace, windows: windows);
  for (final prefix in const ['delete ', 'mkdir ', 'stat ']) {
    if (!command.startsWith(prefix)) continue;
    final path = charFrom(command, prefix.length);
    return path.isEmpty ? command : '${prefix.trim()} ${label(path)}';
  }
  for (final prefix in const ['move ', 'copy ']) {
    if (!command.startsWith(prefix)) continue;
    final parts = charFrom(command, prefix.length).split(' -> ');
    if (parts.length != 2) return command;
    return '${prefix.trim()} ${label(parts.first)} → ${label(parts[1])}';
  }
  const read = 'read ';
  if (command.startsWith(read)) {
    final path = command.replaceFirst(read, '');
    if (path.isNotEmpty) return 'read ${label(path)}';
  }
  return command;
}

/// Заголовок группы шагов. Длительность не раздвигает строку: на узкой карточке она сокращается.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({
    required this.title,
    required this.titleColor,
    required this.duration,
    required this.durationColor,
    required this.accent,
    required this.icon,
    required this.expanded,
  });

  final String title;
  final Color titleColor;
  final String? duration;
  final Color durationColor;
  final Color accent;
  final IconData icon;
  final bool expanded;

  /// Иконка, зазор до заголовка, зазор до шеврона и сам шеврон. Это место длительность не занимает.
  static const _fixed = AppSpacing.sm + AppSpacing.xs + 16.0 + 18.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final durationText = duration;
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = math.max(0.0, constraints.maxWidth - _fixed);
        // Длительность не забирает заголовок: ей остаётся то, что шире короткой полосы пути.
        final durationCap = math.max(0.0, room - AppSpacing.sm - 48);
        return Row(
          children: [
            Icon(icon, size: 16, color: accent),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(color: titleColor),
              ),
            ),
            if (durationText != null && durationCap > 0) ...[
              const SizedBox(width: AppSpacing.sm),
              _CappedText(
                durationText,
                maxWidth: durationCap,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: durationColor,
                ),
              ),
            ],
            const SizedBox(width: AppSpacing.xs),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0,
              duration: AppDurations.fast,
              curve: Curves.easeOutCubic,
              child: Icon(Icons.expand_more, size: 18, color: durationColor),
            ),
          ],
        );
      },
    );
  }
}

/// Заголовок шага: путь, счётчики строк и служебные подписи.
///
/// На широкой карточке подписи стоят справа целиком. На узкой путь сокращается первым,
/// затем подписи: их естественная ширина иначе раздвигает [Row] и рисует жёлтую полосу.
class _StepHeading extends StatelessWidget {
  const _StepHeading({
    required this.title,
    required this.color,
    required this.change,
    required this.meta,
    required this.metaColor,
    required this.background,
  });

  final String title;
  final Color color;
  final FileChange? change;
  final String? meta;
  final Color metaColor;
  final String? background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final change = this.change;
    final added = change?.added ?? 0;
    final removed = change?.removed ?? 0;
    final titleStyle = _paintedStyle(
      context,
      const TextStyle(fontFamily: AppTheme.monoFamily, fontSize: 13),
    ).copyWith(color: color);
    final metaStyle = _paintedStyle(
      context,
      theme.textTheme.labelSmall,
    ).copyWith(color: metaColor);
    final statsStyle = _paintedStyle(context, theme.textTheme.labelSmall);
    return LayoutBuilder(
      builder: (context, constraints) => _StepHeadingBody(
        maxWidth: constraints.maxWidth,
        title: title,
        titleStyle: titleStyle,
        added: added,
        removed: removed,
        statsStyle: statsStyle,
        meta: meta,
        metaStyle: metaStyle,
        background: background,
      ),
    );
  }
}

/// Строка заголовка шага в уже известной ширине. Считает естественные ширины и не выходит за них.
class _StepHeadingBody extends StatelessWidget {
  const _StepHeadingBody({
    required this.maxWidth,
    required this.title,
    required this.titleStyle,
    required this.added,
    required this.removed,
    required this.statsStyle,
    required this.meta,
    required this.metaStyle,
    required this.background,
  });

  final double maxWidth;
  final String title;
  final TextStyle titleStyle;
  final int added;
  final int removed;
  final TextStyle statsStyle;
  final String? meta;
  final TextStyle metaStyle;
  final String? background;

  @override
  Widget build(BuildContext context) {
    final width = maxWidth;
    if (width <= 0) return const SizedBox.shrink();
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    final titleWidth = _textWidth(title, titleStyle, direction, scaler, locale);
    final statsWidth = _statsWidth(statsStyle, direction, scaler, locale);
    final metaText = meta;
    final metaWidth = metaText == null
        ? 0.0
        : _textWidth(metaText, metaStyle, direction, scaler, locale) +
              AppSpacing.sm;
    final backgroundText = background;
    final backgroundWidth = backgroundText == null
        ? 0.0
        : _textWidth(backgroundText, metaStyle, direction, scaler, locale) +
              AppSpacing.sm;
    final left = titleWidth + statsWidth;
    final right = metaWidth + backgroundWidth;
    // Между счётчиком строк и временем. При раскрытии кнопки съедают свободное место,
    // и без своего зазора `+N` слипается с длительностью.
    final between = statsWidth > 0 && metaText != null ? AppSpacing.sm : 0.0;
    if (left + between + right <= width) {
      return Row(
        children: [
          _CappedText(title, maxWidth: titleWidth, style: titleStyle),
          if (statsWidth > 0)
            _ChangeStats(added: added, removed: removed, style: statsStyle),
          if (between > 0) const SizedBox(width: AppSpacing.sm),
          const Spacer(),
          if (metaText != null)
            _MorphLabel(
              metaText,
              keyName: metaText,
              maxWidth: metaWidth,
              style: metaStyle,
            ),
          if (backgroundText != null)
            _MorphLabel(
              backgroundText,
              keyName: 'background',
              maxWidth: backgroundWidth,
              style: metaStyle,
            ),
        ],
      );
    }

    // Путь оставляет себе хотя бы короткую полосу, остальное отдают подписи.
    final usable = math.max(0.0, width - between);
    final titleFloor = math.min(48.0, usable);
    final rightWidth = math.min(right, math.max(0.0, usable - titleFloor));
    final leftWidth = usable - rightWidth;
    return Row(
      children: [
        _LeftCluster(
          width: leftWidth,
          title: title,
          titleStyle: titleStyle,
          added: added,
          removed: removed,
          statsStyle: statsStyle,
          statsWidth: statsWidth,
        ),
        if (between > 0 && leftWidth > 0 && rightWidth > 0)
          const SizedBox(width: AppSpacing.sm),
        if (rightWidth > 0)
          _RightCluster(
            width: rightWidth,
            meta: metaText,
            background: backgroundText,
            style: metaStyle,
          ),
      ],
    );
  }

  double _statsWidth(
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
    Locale? locale,
  ) {
    var width = 0.0;
    if (added > 0) {
      width +=
          AppSpacing.sm +
          _textWidth('+$added', style, direction, scaler, locale);
    }
    if (removed > 0) {
      width +=
          AppSpacing.sm +
          _textWidth('-$removed', style, direction, scaler, locale);
    }
    return width;
  }
}

/// Левая часть шапки, когда всё вместе не помещается: путь сокращается, счётчики живут на остатке.
class _LeftCluster extends StatelessWidget {
  const _LeftCluster({
    required this.width,
    required this.title,
    required this.titleStyle,
    required this.added,
    required this.removed,
    required this.statsStyle,
    required this.statsWidth,
  });

  final double width;
  final String title;
  final TextStyle titleStyle;
  final int added;
  final int removed;
  final TextStyle statsStyle;
  final double statsWidth;

  @override
  Widget build(BuildContext context) {
    if (width <= 0) return const SizedBox.shrink();
    final badges = statsWidth;
    if (badges > 0 && badges <= width) {
      return SizedBox(
        width: width,
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
            if (statsWidth > 0)
              _ChangeStats(added: added, removed: removed, style: statsStyle),
          ],
        ),
      );
    }
    // Счётчики не помещаются целиком: путь оставляет им до 62% строки, текст сокращается.
    final badgeSlice = math.min(badges, width * 0.62);
    if (badgeSlice < 12) {
      return SizedBox(
        width: width,
        child: Text(
          title,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
      );
    }
    final colors = context.appColors;
    return SizedBox(
      width: width,
      child: Row(
        children: [
          SizedBox(
            width: width - badgeSlice,
            child: Text(
              title,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: titleStyle,
            ),
          ),
          SizedBox(
            width: badgeSlice,
            child: Row(
              children: [
                if (added > 0)
                  Flexible(
                    child: Text(
                      '+$added',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: statsStyle.copyWith(color: colors.diffAddText),
                    ),
                  ),
                if (removed > 0)
                  Flexible(
                    child: Text(
                      '-$removed',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: statsStyle.copyWith(color: colors.diffRemoveText),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Подписи справа от пути. В тесноте делят остаток и сокращаются, а не раздвигают шапку.
class _RightCluster extends StatelessWidget {
  const _RightCluster({
    required this.width,
    required this.meta,
    required this.background,
    required this.style,
  });

  final double width;
  final String? meta;
  final String? background;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final metaText = meta;
    final backgroundText = background;
    return SizedBox(
      width: width,
      child: Row(
        children: [
          if (metaText != null)
            Flexible(
              child: _MorphLabel(metaText, keyName: metaText, style: style),
            ),
          if (backgroundText != null)
            Flexible(
              child: _MorphLabel(
                backgroundText,
                keyName: 'background',
                style: style,
              ),
            ),
        ],
      ),
    );
  }
}

/// Подпись, которая проявляется и сжимается вместе со сменой текста.
class _MorphLabel extends StatelessWidget {
  const _MorphLabel(
    this.text, {
    required this.keyName,
    required this.style,
    this.maxWidth,
  });

  final String text;
  final String keyName;
  final TextStyle style;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final cap = maxWidth;
    final label = Text(
      key: ValueKey(keyName),
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (cap == null) return ChatMorph(child: label);
    return ChatMorph(
      child: Row(
        key: ValueKey(keyName),
        mainAxisSize: MainAxisSize.min,
        children: [
          _CappedText(
            text,
            maxWidth: math.max(0, cap - AppSpacing.sm),
            style: style,
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
    );
  }
}

/// Текст не шире [maxWidth]. Зазор слева входит в бюджет родителя, но не в потолок самого текста.
class _CappedText extends StatelessWidget {
  const _CappedText(
    this.text, {
    required this.maxWidth,
    required this.style,
    this.leading = 0,
  });

  final String text;
  final double maxWidth;
  final TextStyle? style;
  final double leading;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (leading > 0) SizedBox(width: leading),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: math.max(0, maxWidth)),
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    ],
  );
}

/// Стиль, которым [Text] реально рисует строку: с масштабом и интервалом темы.
///
/// Незаданные поля стиля не сбрасывают интервал родителя, поэтому ширина считается
/// по уже склеенному стилю. Иначе бюджет колонки короче нарисованного текста.
TextStyle _paintedStyle(BuildContext context, TextStyle? style) {
  final base = DefaultTextStyle.of(context).style;
  final merged = style == null || style.inherit ? base.merge(style) : style;
  return merged.copyWith(inherit: false);
}

double _textWidth(
  String text,
  TextStyle style,
  TextDirection direction,
  TextScaler scaler,
  Locale? locale,
) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: scaler,
    locale: locale,
    maxLines: 1,
  )..layout();
  final width = painter.width.ceilToDouble();
  painter.dispose();
  return width;
}

/// Счётчики `+N` и `-M` в цветах diff. Нулевой счётчик не показывается.
///
/// Каждый счётчик ограничен своей измеренной шириной: иначе длинный `+N` рядом с коротким `-M`
/// делился бы поровну и обрезался даже там, где места хватает.
class _ChangeStats extends StatelessWidget {
  const _ChangeStats({
    required this.added,
    required this.removed,
    required this.style,
  });

  final int added;
  final int removed;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (added == 0 && removed == 0) return const SizedBox.shrink();
    final colors = context.appColors;
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (added > 0)
          _CappedText(
            '+$added',
            maxWidth: _textWidth('+$added', style, direction, scaler, locale),
            style: style.copyWith(color: colors.diffAddText),
            leading: AppSpacing.sm,
          ),
        if (removed > 0)
          _CappedText(
            '-$removed',
            maxWidth: _textWidth('-$removed', style, direction, scaler, locale),
            style: style.copyWith(color: colors.diffRemoveText),
            leading: AppSpacing.sm,
          ),
      ],
    );
  }
}
