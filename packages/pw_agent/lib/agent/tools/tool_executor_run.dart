part of 'tool_executor.dart';

extension _ToolExecutorRun on ToolExecutor {
  // ---- run output --------------------------------------------------------

  /// Список запусков этого чата: id, статус, инструмент, команда и признак
  /// доступного сохранённого вывода. Новые сверху.
  Future<ToolResult> _listRuns(ToolContext ctx) async {
    final runs = await _chats.toolRunsForChat(ctx.chat.id);
    if (runs.isEmpty) return const ToolResult('no tool runs in this chat');
    final sorted = List<ToolRun>.of(runs)
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final lines = <String>[];
    for (final run in sorted.take(100)) {
      final output = run.outputText;
      lines.add(
        [
          run.id,
          run.status.name,
          run.toolName,
          run.background ? 'background' : 'foreground',
          output == null
              ? 'no-output'
              : 'output ${output.characters.length} chars',
          Redactor.redact(run.command ?? ''),
        ].join(' | '),
      );
    }
    if (sorted.length > 100) {
      lines.add('[more runs not shown: ${sorted.length - 100}]');
    }
    return ToolResult(lines.join('\n'));
  }

  /// Постраничное чтение сохранённого вывода. Пока команда идёт, файл ещё не
  /// перенесён в БД: возвращаем статус, а не пустой успех.
  Future<ToolResult> _readRunOutput(
    ToolContext ctx,
    Map<String, dynamic> args,
  ) async {
    final id = toolStringArg(args, 'run_id');
    final run = await _chats.toolRun(id);
    if (run == null || run.chatId != ctx.chat.id) {
      return ToolResult('run not found in this chat: $id', isError: true);
    }
    final offset = _intArg(args, 'offset', min: 0, fallback: 0);
    final limit = _intArg(args, 'limit', min: 1, max: 60000, fallback: 20000);
    final header = [
      'run_id: ${run.id}',
      'status: ${run.status.name}',
      'tool: ${run.toolName}',
      if (run.command != null) 'command: ${Redactor.redact(run.command!)}',
      if (run.outputTruncated) 'output: truncated in storage',
    ];
    final text = run.outputText;
    if (text == null || text.isEmpty) {
      if (run.isActive) {
        header.add(
          'output is not stored until the run finishes; use the live log in the UI',
        );
      } else {
        header.add('no output');
      }
      return ToolResult(header.join('\n'));
    }
    final rest = charFrom(text, offset);
    if (rest.isEmpty) {
      header.add(
        'offset $offset is past the end (${text.characters.length} chars)',
      );
      return ToolResult(header.join('\n'));
    }
    final body = charPrefix(rest, limit);
    final next = offset + body.characters.length;
    final more = next < text.characters.length;
    header
      ..add('offset: $offset')
      ..add('total: ${text.characters.length} chars')
      ..add(more ? '[more: continue with offset=$next]' : '[end]');
    return ToolResult('${header.join('\n')}\n\n$body');
  }

  /// Останавливает запуск по id. В Ask это подтверждается как управление процессом.
  Future<ToolResult> _stopRun(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final id = toolStringArg(args, 'run_id');
    final run = await _chats.toolRun(id);
    if (run == null || run.chatId != ctx.chat.id) {
      return ToolResult('run not found in this chat: $id', isError: true);
    }
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, 'stop denied by policy');
    }
    final runId = ToolExecutor._uuid.v4();
    if (decision == PolicyDecision.ask) {
      final approved = await _approve(
        ctx,
        call,
        args,
        runId: runId,
        command: 'stop run $id',
        summary: id,
        reason: 'process control',
      );
      if (!approved.allowed) {
        return _rejected(id, reason: approved.reason);
      }
    }
    final stopped = await _commands.stopRun(id);
    await _saveRun(
      _newRun(
        ctx,
        runId,
        call,
        args,
        stopped ? ToolRunStatus.done : ToolRunStatus.failed,
        command: 'stop run $id',
        finishedAt: DateTime.now(),
      ).copyWith(
        resultPreview: stopped ? 'stop requested' : 'run is not active',
      ),
    );
    return ToolResult(
      stopped
          ? 'stop requested for run $id'
          : 'run $id is not active (already finished or unknown)',
      isError: !stopped,
    );
  }
}
