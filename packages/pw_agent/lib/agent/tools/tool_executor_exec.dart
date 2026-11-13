part of 'tool_executor.dart';

extension _ToolExecutorExec on ToolExecutor {
  // ---- execution core ----------------------------------------------------

  Future<ToolResult> _exec(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args, {
    required String command,
    String? execCommand,
    required bool background,
    String? cwd,
    String? presetRunId,
    bool inTerminal = false,
    Uint8List? stdin,
    Duration? timeout,
    HostOp? op,
    DateTime? startedAt,
  }) async {
    final runId = presetRunId ?? ToolExecutor._uuid.v4();
    var run = _newRun(
      ctx,
      runId,
      call,
      args,
      ToolRunStatus.running,
      command: command,
      background: background,
      startedAt: startedAt,
    );
    await _saveRun(run);

    final handle = await _commands.start(
      chatId: ctx.chat.id,
      hostId: ctx.host.id,
      toolCallId: runId,
      runtime: ctx.runtime,
      command: execCommand ?? command,
      displayCommand: command,
      cwd: cwd,
      limits: ctx.limits,
      background: background,
      inTerminal: inTerminal,
      stdin: stdin,
      timeout: timeout,
      op: op,
    );
    run = run.copyWith(logPath: handle.logPath);
    await _saveRun(run);

    final pid = await handle.started;
    if (pid != null) {
      run = run.copyWith(pid: pid);
      await _saveRun(run);
    }

    if (background && pid != null) {
      run = run.copyWith(status: ToolRunStatus.backgroundRunning);
      await _saveRun(run);
      // Текст для модели готов сразу. Зависимые вызовы этого батча ждут
      // процесс: иначе чтение «для проверки» попало бы в ещё идущую команду.
      final settled = Completer<void>();
      unawaited(() async {
        try {
          final outcome = await handle.finished;
          final finished = await _complete(run, outcome);
          await _recordShellIfNeeded(
            ctx,
            call,
            args,
            finished,
            command: command,
          );
          ctx.onBackgroundDone(finished, outcome);
        } finally {
          if (!settled.isCompleted) settled.complete();
        }
      }());
      return ToolResult(
        'started in background (run $runId, pid $pid). You will be notified when it finishes.',
        whenSettled: settled.future,
      );
    }

    final outcome = await handle.finished;
    final finished = await _complete(run, outcome);
    await _recordShellIfNeeded(ctx, call, args, finished, command: command);
    if (finished.status == ToolRunStatus.done &&
        op is WriteFileOp &&
        isEphemeralHostWriteBackup(op.backupPath)) {
      await _discardEphemeralWriteBackup(ctx, op.backupPath);
    }
    return ToolResult(
      _modelText(outcome, ctx.limits, finished.id),
      isError: outcome.status != ToolRunStatus.done,
    );
  }

  Future<void> _discardEphemeralWriteBackup(
    ToolContext ctx,
    String backupPath,
  ) async {
    if (ctx.host.kind == HostKind.local) {
      try {
        final file = File(backupPath);
        if (file.existsSync()) file.deleteSync();
      } on Object {
        return;
      }
      return;
    }
    final adapter = ShellAdapter(ctx.runtime.os);
    final command = switch (ctx.runtime.os) {
      HostOs.windows => adapter.powershell(
        'Remove-Item -LiteralPath ${psQuote(backupPath)} '
        '-Force -ErrorAction SilentlyContinue',
      ),
      _ => 'rm -f -- ${adapter.quotePath(backupPath)}',
    };
    unawaited(captureRun(ctx.runtime, command));
  }

  Future<void> _recordShellIfNeeded(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    ToolRun run, {
    required String command,
  }) async {
    if (call.name != ToolNames.runCommand) return;
    if (run.status != ToolRunStatus.done) return;
    final turnId = ctx.turnUserMessageId;
    if (turnId == null) return;
    final raw = args['command'];
    final cmd = raw is String && raw.trim().isNotEmpty ? raw : command;
    await _changesets.recordShellMutation(
      chatId: ctx.chat.id,
      turnId: turnId,
      toolRunId: run.id,
      classifier: ctx.policy.classifier,
      command: cmd,
    );
  }

  Future<ToolRun> _complete(ToolRun run, ExecOutcome outcome) async {
    final done = run.copyWith(
      status: outcome.status,
      exitCode: outcome.exitCode,
      timedOut: outcome.status == ToolRunStatus.timedOut,
      pid: outcome.pid,
      outputText: outcome.outputText,
      outputTruncated: outcome.outputTruncated,
      resultPreview: previewToolText(
        outcome.outputText.isEmpty
            ? (outcome.message ?? outcome.status.name)
            : outcome.outputText,
      ),
      finishedAt: DateTime.now(),
      clearLogPath: true,
    );
    await _saveRun(done);
    return done;
  }
}
