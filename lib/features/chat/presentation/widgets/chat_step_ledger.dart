import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/host/host_terminal.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

/// Журнал шагов одного ответа ассистента: все команды, которые он выполнил.
///
/// Свернутая группа занимает одну строку с итогом. Раскрывается сама, пока есть активные шаги
/// или шаги, требующие внимания (ожидание, ошибка). Ошибки никогда не прячутся
/// в свёрнутом виде: без них история не читается.
class ChatStepLedger extends StatefulWidget {
  const ChatStepLedger({
    required this.runs,
    required this.live,
    this.terminalFor,
    super.key,
  });

  final List<ToolRun> runs;
  final Map<String, String> live;

  /// Терминал активного запуска по его id; `null`, если запуск не выполняется в PTY.
  final HostTerminal? Function(String runId)? terminalFor;

  @override
  State<ChatStepLedger> createState() => _ChatStepLedgerState();
}

class _ChatStepLedgerState extends State<ChatStepLedger> {
  /// Выбор пользователя; `null` — раскрытие определяется состоянием шагов.
  bool? _userExpanded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final runs = widget.runs;

    var active = 0;
    var failed = 0;
    var attention = false;
    var done = 0;
    for (final run in runs) {
      if (run.isActive || run.status == ToolRunStatus.backgroundRunning) {
        active++;
      }
      if (_isFailure(run)) failed++;
      if (_needsAttention(run)) attention = true;
      if (run.status == ToolRunStatus.done) done++;
    }

    final expanded = _userExpanded ?? (active > 0 || attention || failed > 0);
    final tone = failed > 0
        ? AppTone.danger
        : active > 0
        ? AppTone.progress
        : attention
        ? AppTone.waiting
        : AppTone.success;
    final title = active > 0
        ? l10n.stepsGroupActive(done, runs.length)
        : l10n.stepsGroupDone(runs.length);
    final duration = _groupDuration(runs);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: AppRadius.smAll,
            onTap: () => setState(() => _userExpanded = !expanded),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: Row(
                children: [
                  Icon(
                    _groupIcon(tone),
                    size: 16,
                    color: toneColors(context, tone).foreground,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      failed > 0
                          ? '$title · ${l10n.stepsGroupFailed(failed)}'
                          : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (duration != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      l10n.runDuration(duration.inSeconds),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(width: AppSpacing.xs),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.sm,
                top: AppSpacing.xs,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final run in runs)
                        _StepRow(
                          key: ValueKey(run.id),
                          run: run,
                          live: widget.live[run.id],
                          terminal: widget.terminalFor?.call(run.id),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
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

  /// Общее время группы: от первого запуска до последнего завершения (или до текущего момента).
  static Duration? _groupDuration(List<ToolRun> runs) {
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

/// Одна строка журнала: статус текстом, команда в моно-шрифте, вывод раскрывается по нажатию.
class _StepRow extends StatefulWidget {
  const _StepRow({
    required this.run,
    required this.live,
    this.terminal,
    super.key,
  });

  final ToolRun run;
  final String? live;
  final HostTerminal? terminal;

  @override
  State<_StepRow> createState() => _StepRowState();
}

class _StepRowState extends State<_StepRow> {
  late var _expanded = widget.run.isActive;

  @override
  void didUpdateWidget(covariant _StepRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Активный шаг раскрываем, чтобы был виден вывод; завершённый не трогаем.
    if (!oldWidget.run.isActive && widget.run.isActive) _expanded = true;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final run = widget.run;
    final output = widget.live ?? run.outputText ?? '';
    final active =
        run.isActive || run.status == ToolRunStatus.backgroundRunning;
    final visual = _visualOf(run, l10n);
    final finishedAt = run.finishedAt;
    final meta = [
      if (run.pid != null) l10n.runPid(run.pid!),
      if (finishedAt != null)
        l10n.runDuration(finishedAt.difference(run.startedAt).inSeconds),
    ];
    // Активный шаг с PTY показывает терминал сразу, даже до первого байта вывода.
    final terminal = active ? widget.terminal : null;
    final canExpand = output.isNotEmpty || terminal != null;
    final tone = toneColors(context, visual.tone).foreground;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          borderRadius: AppRadius.smAll,
          onTap: canExpand
              ? () => setState(() => _expanded = !_expanded)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: [
                Icon(visual.icon, size: 16, color: tone),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    run.command ?? run.toolName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppTheme.monoFamily,
                      fontSize: 13,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  Text(
                    meta.join(' · '),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                if (run.background) ...[
                  Text(
                    l10n.runBackgroundBadge,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Text(
                  visual.label,
                  style: theme.textTheme.labelMedium?.copyWith(color: tone),
                ),
                if (active && run.status != ToolRunStatus.waitingApproval)
                  IconButton(
                    tooltip: l10n.runStop,
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    icon: const Icon(Icons.stop_circle_outlined),
                    onPressed: () => context.read<ChatBloc>().add(
                      ChatRunStopRequested(run.id),
                    ),
                  ),
                if (canExpand)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: AppDurations.fast,
          alignment: Alignment.topCenter,
          child: _expanded && canExpand
              ? Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CommandOutput(
                        text: output,
                        exitCode: run.exitCode,
                        active: active,
                        terminal: terminal,
                        maxHeight: active ? 320 : 220,
                      ),
                      if (run.outputTruncated) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          l10n.runOutputTruncated,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
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
