part of 'tool_executor.dart';

extension _ToolExecutorHelpers on ToolExecutor {
  // ---- helpers -----------------------------------------------------------

  Future<ApprovalDecision> _approve(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args, {
    required String runId,
    required String summary,
    required String reason,
    String? command,
    String? diff,
    bool allowStoredGrant = true,
  }) async {
    final permissionKey = '${call.name}\u0000$summary';
    final turnId = ctx.turnUserMessageId;
    // Подтверждение субагента показываем в главном чате, а не в скрытом.
    final approvalChatId = ctx.chat.rootChatId ?? ctx.chat.id;
    if (allowStoredGrant &&
        _broker.hasGrant(
          chatId: approvalChatId,
          turnId: turnId,
          key: permissionKey,
        )) {
      return const ApprovalDecision.allowOnce();
    }
    final card = PendingCard(
      summary: summary,
      reason: reason,
      diff: diff,
      turnId: turnId,
      permissionKey: permissionKey,
      grantable: allowStoredGrant,
    );
    final run = _newRun(
      ctx,
      runId,
      call,
      args,
      ToolRunStatus.waitingApproval,
      command: command,
      pendingCard: card.encode(),
    );
    await _saveRun(run);
    final decision = await _broker.requestApproval(
      ApprovalRequest(
        id: runId,
        chatId: approvalChatId,
        toolName: call.name,
        summary: summary,
        reason: reason,
        diff: diff,
        turnId: turnId,
        permissionKey: permissionKey,
        grantable: allowStoredGrant,
      ),
    );
    if (!decision.allowed) await _denyRun(run, summary);
    return decision;
  }

  /// Ждёт ответ. Карточка уже зарегистрирована вызовом брокера до этого будущего.
  Future<WaitingDecision> _asQuestion(Future<String?> pending) async =>
      WaitingDecision.question(await pending);

  /// Ждёт подтверждение, не откладывая регистрацию карточки.
  Future<WaitingDecision> _asApproval(Future<ApprovalDecision> pending) async =>
      WaitingDecision.approval(await pending);

  Future<ToolResult> _finishQuestion(ToolRun run, String? answer) async {
    final text = answer ?? 'User did not answer (the turn was stopped).';
    await _saveRun(
      run.copyWith(
        status: ToolRunStatus.done,
        finishedAt: DateTime.now(),
        resultPreview: previewToolText(text),
        clearPendingCard: true,
      ),
    );
    return ToolResult(answer == null ? text : 'User answered: $answer');
  }

  /// Отказ — явный ответ: статус больше не waiting, карточка после перезапуска не вернётся.
  Future<ToolResult> _denyRun(
    ToolRun run,
    String summary, {
    String? reason,
  }) async {
    await _saveRun(
      run.copyWith(
        status: ToolRunStatus.denied,
        finishedAt: DateTime.now(),
        clearPendingCard: true,
      ),
    );
    return _rejected(summary, reason: reason);
  }

  Future<ToolResult> _failRun(ToolRun run, String text) async {
    await _saveRun(
      run.copyWith(
        status: ToolRunStatus.failed,
        finishedAt: DateTime.now(),
        resultPreview: previewToolText(text),
        clearPendingCard: true,
      ),
    );
    return ToolResult(text, isError: true);
  }

  /// Продолжение уже подтверждённого действия. Политику заново не спрашиваем:
  /// пользователь ответил на ту карточку, которая была показана.
  Future<ToolResult> _executeApproved(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    ToolRun run,
  ) {
    final handler = _resumeHandlers[call.name];
    if (handler == null) return _failRun(run, 'cannot resume ${call.name}');
    return handler(ctx, call, args, run);
  }

  /// Продолжение подтверждённого чтения. Проверки пути уже пройдены.
  Future<ToolResult> _resumeHostRead(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    ToolRun run,
  ) {
    final path = _resolve(ctx, toolStringArg(args, 'path'));
    final op = _hostOpForRead(ctx, call, args, path);
    return _exec(
      ctx,
      call,
      args,
      command: op.label,
      op: op,
      background: false,
      presetRunId: run.id,
      startedAt: run.startedAt,
    );
  }

  Future<ToolResult> _resumeCommand(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    ToolRun run,
  ) {
    final command = toolStringArg(args, 'command');
    final background = args['background'] == true;
    if (background && ctx.host.kind == HostKind.virtual) {
      return _failRun(
        run,
        'background is not supported on a virtual host: run the command in the foreground',
      );
    }
    final cwdArg = args['cwd'] as String?;
    final cwd = cwdArg == null || cwdArg.isEmpty
        ? _commandCwd(ctx)
        : _resolve(ctx, cwdArg);
    final stdin = _stdinArg(args);
    final timeout = _timeoutArg(ctx, args, background: background);
    return _exec(
      ctx,
      call,
      args,
      command: command,
      execCommand: _withCommandDefaults(ctx, command),
      cwd: cwd,
      background: background,
      presetRunId: run.id,
      inTerminal: stdin == null,
      stdin: stdin,
      timeout: timeout,
      startedAt: run.startedAt,
    );
  }

  Future<ToolResult> _resumeWrite(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    ToolRun run,
  ) async {
    final path = _resolve(ctx, toolStringArg(args, 'path'));
    final content = toolStringArg(args, 'content');
    final mtime = await _mtimeOrNull(ctx, path);
    var before = '';
    if (mtime != null) {
      final read = await captureOp(ctx.runtime, ReadRawOp(path));
      if (read.ok) before = read.stdout;
    }
    final result = await _exec(
      ctx,
      call,
      args,
      command: run.command ?? 'write $path',
      op: WriteFileOp(
        path,
        backupPath: await _resumeBackupPath(ctx, path, run),
        expectedMtime: mtime,
      ),
      background: false,
      presetRunId: run.id,
      stdin: Uint8List.fromList(utf8.encode(content)),
      startedAt: run.startedAt,
    );
    await _recordSuccessfulWriteIfNeeded(
      ctx,
      result,
      path: path,
      before: before,
      fileExisted: mtime != null,
    );
    return result;
  }

  Future<ToolResult> _resumeEdit(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    ToolRun run,
  ) async {
    final path = _resolve(ctx, toolStringArg(args, 'path'));
    final oldString = toolStringArg(args, 'old_string');
    final newString = toolStringArg(args, 'new_string');
    final replaceAll = args['replace_all'] == true;
    final mtime = await _mtimeOrNull(ctx, path);
    final read = await captureOp(ctx.runtime, ReadRawOp(path));
    if (mtime == null || !read.ok) {
      return _failRun(run, 'cannot read $path (file missing or unreadable)');
    }
    final before = read.stdout;
    if (before.contains('\uFFFD')) {
      return _failRun(
        run,
        'cannot edit $path: it is not valid UTF-8 text (or contains U+FFFD), and an edit would corrupt its bytes. The file was not changed.',
      );
    }
    final occurrences = oldString.isEmpty
        ? 0
        : oldString.allMatches(before).length;
    if (occurrences == 0) {
      return _failRun(run, 'old_string not found in $path');
    }
    if (occurrences > 1 && !replaceAll) {
      return _failRun(
        run,
        'old_string matches $occurrences times in $path; provide more context or set replace_all',
      );
    }
    final after = replaceAll
        ? before.replaceAll(oldString, newString)
        : before.replaceFirst(oldString, newString);
    final result = await _exec(
      ctx,
      call,
      args,
      command: run.command ?? 'write $path',
      op: WriteFileOp(
        path,
        backupPath: await _resumeBackupPath(ctx, path, run),
        expectedMtime: mtime,
      ),
      background: false,
      presetRunId: run.id,
      stdin: Uint8List.fromList(utf8.encode(after)),
      startedAt: run.startedAt,
    );
    await _recordSuccessfulWriteIfNeeded(
      ctx,
      result,
      path: path,
      before: before,
      fileExisted: true,
    );
    return result;
  }

  Future<String> _resumeBackupPath(
    ToolContext ctx,
    String path,
    ToolRun run,
  ) async {
    final turnId = ctx.turnUserMessageId;
    if (turnId == null) return '$path.pw-bak-${run.id}';
    return _changesets.prepareHostWriteBackupPath(
      hostKind: ctx.host.kind,
      chatId: ctx.chat.id,
      turnId: turnId,
      targetPath: path,
      toolRunId: run.id,
    );
  }

  Future<ToolResult> _resumeSelf(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    ToolRun run,
  ) async {
    // Запись меняет приложение, а не Host, но запуск должен принадлежать этому чату.
    if (ctx.chat.id != run.chatId) {
      return _failRun(run, 'run ${run.id} belongs to another chat');
    }
    final change = await _self.prepare(call.name, args);
    try {
      final text = await change.apply();
      await _saveRun(
        run.copyWith(
          status: ToolRunStatus.done,
          command: change.summary,
          finishedAt: DateTime.now(),
          resultPreview: previewToolText(text),
          clearPendingCard: true,
        ),
      );
      return ToolResult(text);
    } on Object catch (error) {
      return _failRun(run, '${call.name} failed: $error');
    }
  }

  String _questionText(ToolRun run) {
    final args = _decodeArgs(run.argsJson);
    final question = args?['question'];
    if (question is String && question.isNotEmpty) return question;
    return run.command ?? run.toolName;
  }

  Map<String, dynamic>? _decodeArgs(String raw) {
    try {
      final decoded = raw.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<ToolResult> _denied(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    String reason,
  ) async {
    final run = _newRun(
      ctx,
      ToolExecutor._uuid.v4(),
      call,
      args,
      ToolRunStatus.denied,
      finishedAt: DateTime.now(),
    );
    await _saveRun(run.copyWith(resultPreview: reason));
    return ToolResult('denied by policy: $reason', isError: true);
  }

  ToolResult _rejected(String target, {String? reason}) => ToolResult(
    'the user rejected this action ($target). Do not retry it without a different approach.'
    '${reason == null || reason.trim().isEmpty ? '' : ' Reason: ${reason.trim()}'}',
    isError: true,
  );

  ToolRun _newRun(
    ToolContext ctx,
    String runId,
    LlmToolCall call,
    Map<String, dynamic> args,
    ToolRunStatus status, {
    String? command,
    bool background = false,
    DateTime? finishedAt,
    String? pendingCard,
    DateTime? startedAt,
  }) => ToolRun(
    id: runId,
    chatId: ctx.chat.id,
    messageId: ctx.messageId,
    toolName: call.name,
    argsJson: call.arguments,
    command:
        command ??
        (call.name == ToolNames.runCommand
            ? toolStringArg(args, 'command')
            : null),
    background: background,
    status: status,
    startedAt: startedAt ?? DateTime.now(),
    finishedAt: finishedAt,
    toolCallId: call.id,
    pendingCard: pendingCard,
  );

  /// Неинтерактивные значения по умолчанию для обычных команд. Экспорт не
  /// меняет команду, которую видит модель и журнал, но не даёт пагеру ждать ввода.
  /// На Windows оболочка другая, там значения не подставляются.
  String _withCommandDefaults(ToolContext ctx, String command) {
    if (ctx.runtime.os == HostOs.windows) return command;
    const prefix =
        r'export PAGER="${PAGER:-cat}" GIT_PAGER="${GIT_PAGER:-cat}" '
        r'CI="${CI:-1}"; ';
    return '$prefix$command';
  }

  /// Необязательный stdin. Пустая строка — явный EOF, отсутствие ключа — PTY.
  Uint8List? _stdinArg(Map<String, dynamic> args) {
    if (!args.containsKey('stdin')) return null;
    final value = args['stdin'];
    if (value is! String) {
      throw ArgumentError.value(value, 'stdin', 'string expected');
    }
    return Uint8List.fromList(utf8.encode(value));
  }

  /// Таймаут конкретной команды. Не даёт обойти лимиты из Settings: запрошенное
  /// значение ограничено тем же пределом, что и обычный запуск.
  Duration? _timeoutArg(
    ToolContext ctx,
    Map<String, dynamic> args, {
    required bool background,
  }) {
    final seconds = args['timeout'] == null
        ? null
        : _intArg(args, 'timeout', min: 1, max: 86400, fallback: 1);
    if (seconds == null) return null;
    final requested = Duration(seconds: seconds);
    final limit = background
        ? ctx.limits.backgroundMaxRuntime
        : ctx.limits.foregroundExecTimeout;
    if (requested > limit) {
      throw ArgumentError('timeout must not exceed ${limit.inSeconds} seconds');
    }
    return requested;
  }

  /// Каталог команд. Папка чата, папка хоста или дом. Дом в проект не записывается.
  String _commandCwd(ToolContext ctx) =>
      commandWorkspace(ctx.host, ctx.chat.workspace);

  String _resolve(ToolContext ctx, String path) =>
      hostToolPath(_commandCwd(ctx), path);

  Future<String> _readOrEmpty(ToolContext ctx, String path) async {
    final read = await captureOp(ctx.runtime, ReadRawOp(path));
    return read.ok ? read.stdout : '';
  }

  String _renderDiff(String before, String after) {
    final lines = LineDiff.compute(before, after);
    final buffer = StringBuffer();
    var count = 0;
    for (final line in lines) {
      if (line.kind == DiffKind.same) continue;
      if (count++ >= ToolExecutor._maxDiffLines) {
        buffer.writeln('… diff truncated');
        break;
      }
      buffer.writeln('${line.kind == DiffKind.add ? '+' : '-'} ${line.text}');
    }
    return buffer.toString();
  }

  String _modelText(ExecOutcome outcome, AppLimits limits, String runId) {
    final header = [
      'run_id: $runId',
      'status: ${outcome.status.name}',
      if (outcome.exitCode != null) 'exit_code: ${outcome.exitCode}',
      if (outcome.message != null && outcome.message!.isNotEmpty)
        'message: ${outcome.message}',
      if (outcome.outputTruncated) 'output: truncated (head and tail kept)',
    ].join('\n');
    final body = TextClip.headTail(
      plainTerminalText(outcome.outputText),
      maxChars: limits.toolOutputForModelChars,
    );
    return body.isEmpty ? header : '$header\n$body';
  }

  /// Необязательное целое. Дробные значения и значения ниже [min] — ошибка аргумента, а не молчаливая подмена.
  int _intArg(
    Map<String, dynamic> args,
    String key, {
    required int min,
    int? max,
    required int fallback,
  }) {
    final value = args[key];
    if (value == null) return fallback;
    if (value is! num || value != value.toInt()) {
      throw ArgumentError.value(value, key, 'integer expected');
    }
    final number = value.toInt();
    if (number < min) {
      throw ArgumentError.value(value, key, 'must be at least $min');
    }
    return max == null ? number : math.min(number, max);
  }
}
