part of 'chat_step_ledger.dart';

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
