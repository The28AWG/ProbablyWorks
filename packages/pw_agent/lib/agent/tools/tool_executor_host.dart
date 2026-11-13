part of 'tool_executor.dart';

extension _ToolExecutorHost on ToolExecutor {
  // ---- host commands -----------------------------------------------------

  /// Служебная операция Host: политика, затем выполнение через рантайм. Команды в журнале нет,
  /// поэтому в журнал и шаг идёт подпись операции [HostOp.label].
  Future<ToolResult> _hostOp(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    HostOp op, {
    String? guardedPath,
    bool recursive = false,
  }) async {
    var decision = ctx.policy.decide(call.name, args);
    var reason = ctx.policy.reasonFor(call.name, args);
    var grantable = true;
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, reason);
    }
    if (guardedPath != null) {
      final paths = SensitivePaths.current(
        remote: ctx.host.kind != HostKind.local,
      );
      final sensitive = paths.sensitiveReason(
        guardedPath,
        recursive: recursive,
      );
      if (sensitive != null) {
        decision = PolicyDecision.ask;
        reason = sensitive;
        grantable = false;
      } else if (decision == PolicyDecision.allow &&
          ctx.policy.mode == PolicyMode.ask &&
          !paths.isInsideWorkspace(guardedPath, _commandCwd(ctx))) {
        decision = PolicyDecision.ask;
        reason = 'path is outside the project workspace';
      }
    }
    if (decision == PolicyDecision.ask) {
      final runId = ToolExecutor._uuid.v4();
      final approved = await _approve(
        ctx,
        call,
        args,
        runId: runId,
        summary: op.label,
        reason: reason,
        allowStoredGrant: grantable,
      );
      if (!approved.allowed) {
        return _rejected(op.label, reason: approved.reason);
      }
      return _exec(
        ctx,
        call,
        args,
        command: op.label,
        op: op,
        background: false,
        presetRunId: runId,
      );
    }
    return _exec(ctx, call, args, command: op.label, op: op, background: false);
  }

  Future<ToolResult> _runCommand(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final command = toolStringArg(args, 'command');
    final background = args['background'] == true;
    // У виртуального Host нет процессов, которые можно отпустить в фон. Отказ сразу, без запуска и без
    // подтверждения: модель должна повторить команду в обычном режиме.
    if (background && ctx.host.kind == HostKind.virtual) {
      return ToolResult(
        'background is not supported on a virtual host: run the command in the foreground',
        isError: true,
      );
    }
    final cwdArg = args['cwd'] as String?;
    // Относительный cwd считается от workspace, как и пути остальных инструментов.
    final cwd = cwdArg == null || cwdArg.isEmpty
        ? _commandCwd(ctx)
        : _resolve(ctx, cwdArg);
    final stdin = _stdinArg(args);
    final timeout = _timeoutArg(ctx, args, background: background);
    // Один id на всю жизнь команды: ожидание подтверждения и выполнение — одна строка в журнале.
    final runId = ToolExecutor._uuid.v4();
    final decision = ctx.policy.decide(call.name, args);
    switch (decision) {
      case PolicyDecision.deny:
        return _denied(ctx, call, args, ctx.policy.reasonFor(call.name, args));
      case PolicyDecision.ask:
        final approved = await _approve(
          ctx,
          call,
          args,
          runId: runId,
          summary: command,
          reason: ctx.policy.reasonFor(call.name, args),
        );
        if (!approved.allowed) {
          return _rejected(command, reason: approved.reason);
        }
        break;
      case PolicyDecision.allow:
        break;
    }
    return _exec(
      ctx,
      call,
      args,
      command: command,
      execCommand: _withCommandDefaults(ctx, command),
      cwd: cwd,
      background: background,
      presetRunId: runId,
      // stdin означает поток без PTY: иначе байты некуда подать до старта.
      inTerminal: stdin == null,
      stdin: stdin,
      timeout: timeout,
    );
  }

  Future<ToolResult> _writeFile(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final path = _resolve(ctx, toolStringArg(args, 'path'));
    final content = toolStringArg(args, 'content');
    final mtime = await _mtimeOrNull(ctx, path);
    final before = await _readOrEmpty(ctx, path);
    return _mutateFile(
      ctx,
      call,
      args,
      path: path,
      before: before,
      after: content,
      expectedMtime: mtime,
    );
  }

  /// mtime файла на Host или null, если файла нет (или его не удалось получить: тогда запись
  /// безопасно откажет, потому что файл существует, а ожидался отсутствующий).
  Future<String?> _mtimeOrNull(ToolContext ctx, String path) async {
    final run = await captureOp(ctx.runtime, StatOp(path));
    if (!run.ok) return null;
    return StatResult.parse(run.stdout)?.mtime;
  }

  Future<ToolResult> _editFile(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final path = _resolve(ctx, toolStringArg(args, 'path'));
    final oldString = toolStringArg(args, 'old_string');
    final newString = toolStringArg(args, 'new_string');
    final replaceAll = args['replace_all'] == true;
    // mtime снимается раньше содержимого: если файл изменится между ними, защита записи это заметит.
    final mtime = await _mtimeOrNull(ctx, path);
    final read = await captureOp(ctx.runtime, ReadRawOp(path));
    if (mtime == null || !read.ok) {
      return ToolResult(
        'cannot read $path (file missing or unreadable)',
        isError: true,
      );
    }
    final before = read.stdout;
    // Декодер заменяет байты не в UTF-8 на U+FFFD. Запись такого текста обратно испортила бы файл.
    if (before.contains('\uFFFD')) {
      return ToolResult(
        'cannot edit $path: it is not valid UTF-8 text (or contains U+FFFD), and an edit would corrupt its bytes. The file was not changed.',
        isError: true,
      );
    }
    final occurrences = oldString.isEmpty
        ? 0
        : oldString.allMatches(before).length;
    if (occurrences == 0) {
      return ToolResult('old_string not found in $path', isError: true);
    }
    if (occurrences > 1 && !replaceAll) {
      return ToolResult(
        'old_string matches $occurrences times in $path; provide more context or set replace_all',
        isError: true,
      );
    }
    final after = replaceAll
        ? before.replaceAll(oldString, newString)
        : before.replaceFirst(oldString, newString);
    return _mutateFile(
      ctx,
      call,
      args,
      path: path,
      before: before,
      after: after,
      expectedMtime: mtime,
    );
  }

  /// Применяет unified diff целиком. Патч сначала разбирается и проверяется
  /// по исходному тексту; при любом несовпадении файл не меняется.
  Future<ToolResult> _applyPatch(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final path = _resolve(ctx, toolStringArg(args, 'path'));
    final raw = toolStringArg(args, 'patch');
    final UnifiedDiff patch;
    try {
      patch = parseUnifiedDiff(raw);
    } on FormatException catch (error) {
      return ToolResult('invalid patch: ${error.message}', isError: true);
    }
    final mtime = await _mtimeOrNull(ctx, path);
    final before = await _readTextOrNull(ctx, path);
    if (mtime == null || before == null) {
      return ToolResult(
        'cannot apply patch to $path (file missing or unreadable)',
        isError: true,
      );
    }
    if (before.contains('\uFFFD')) {
      return ToolResult(
        'cannot apply patch to $path: it is not valid UTF-8 text',
        isError: true,
      );
    }
    final String after;
    try {
      after = applyUnifiedDiff(before, patch);
    } on FormatException catch (error) {
      return ToolResult(
        'patch does not apply to $path: ${error.message}',
        isError: true,
      );
    }
    if (after == before) {
      return ToolResult('patch made no changes in $path', isError: true);
    }
    return _mutateFile(
      ctx,
      call,
      args,
      path: path,
      before: before,
      after: after,
      expectedMtime: mtime,
    );
  }

  /// Удаление обычного файла или симлинка. Текст сохраняется для отката; если
  /// прочитать файл нельзя или он бинарный, ход помечается как неоткатываемый.
  Future<ToolResult> _deleteFile(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final path = _resolve(ctx, toolStringArg(args, 'path'));
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, 'delete denied by policy');
    }
    final stat = await _statOrNull(ctx, path);
    if (stat == null) {
      return ToolResult('cannot delete $path: path not found', isError: true);
    }
    if (stat.isDir) {
      return ToolResult(
        'cannot delete $path: it is a directory; delete_file removes files only',
        isError: true,
      );
    }
    final before = await _readTextOrNull(ctx, path);
    final runId = ToolExecutor._uuid.v4();
    if (decision == PolicyDecision.ask) {
      final approved = await _approve(
        ctx,
        call,
        args,
        runId: runId,
        command: 'delete $path',
        summary: path,
        reason: 'delete operation',
      );
      if (!approved.allowed) {
        return _rejected(path, reason: approved.reason);
      }
    }
    final result = await _exec(
      ctx,
      call,
      args,
      command: 'delete $path',
      op: DeleteFileOp(path),
      background: false,
      presetRunId: runId,
    );
    if (!result.isError) {
      await _recordDelete(ctx, runId, path, before);
    }
    return result;
  }

  /// Перенос пути. Откат не автоматический: меняются два пути, а changeset
  /// хранит только файлы. Ход помечается как неоткатываемый.
  Future<ToolResult> _movePath(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final from = _resolve(ctx, toolStringArg(args, 'from'));
    final to = _resolve(ctx, toolStringArg(args, 'to'));
    final overwrite = args['overwrite'] == true;
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, 'move denied by policy');
    }
    if (await _statOrNull(ctx, from) == null) {
      return ToolResult('cannot move $from: path not found', isError: true);
    }
    final destination = await _statOrNull(ctx, to);
    if (destination?.isDir == true) {
      return ToolResult(
        'cannot move to $to: target is a directory; pass a full new path',
        isError: true,
      );
    }
    if (!overwrite && destination != null) {
      return ToolResult(
        'cannot move to $to: target exists; set overwrite=true to replace it',
        isError: true,
      );
    }
    final runId = ToolExecutor._uuid.v4();
    if (decision == PolicyDecision.ask) {
      final approved = await _approve(
        ctx,
        call,
        args,
        runId: runId,
        command: 'move $from $to',
        summary: '$from → $to',
        reason: 'move operation',
      );
      if (!approved.allowed) {
        return _rejected('$from → $to', reason: approved.reason);
      }
    }
    final result = await _exec(
      ctx,
      call,
      args,
      command: 'move $from -> $to',
      op: MovePathOp(from, to, overwrite: overwrite),
      background: false,
      presetRunId: runId,
    );
    if (!result.isError) {
      await _recordUnrecoverable(ctx, runId);
    }
    return result;
  }

  /// Копирование обычного файла. Цель учитывается в changeset как запись.
  Future<ToolResult> _copyPath(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final from = _resolve(ctx, toolStringArg(args, 'from'));
    final to = _resolve(ctx, toolStringArg(args, 'to'));
    final overwrite = args['overwrite'] == true;
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, 'copy denied by policy');
    }
    final source = await _statOrNull(ctx, from);
    if (source == null) {
      return ToolResult('cannot copy $from: path not found', isError: true);
    }
    if (source.isDir) {
      return ToolResult(
        'cannot copy $from: directory copy is not supported',
        isError: true,
      );
    }
    final target = await _statOrNull(ctx, to);
    if (target?.isDir == true) {
      return ToolResult(
        'cannot copy to $to: target is a directory; pass a full new path',
        isError: true,
      );
    }
    if (target != null && !overwrite) {
      return ToolResult(
        'cannot copy to $to: target exists; set overwrite=true to replace it',
        isError: true,
      );
    }
    final before = target == null ? null : await _readTextOrNull(ctx, to);
    final runId = ToolExecutor._uuid.v4();
    if (decision == PolicyDecision.ask) {
      final approved = await _approve(
        ctx,
        call,
        args,
        runId: runId,
        command: 'copy $from $to',
        summary: '$from → $to',
        reason: 'copy operation',
      );
      if (!approved.allowed) {
        return _rejected('$from → $to', reason: approved.reason);
      }
    }
    final result = await _exec(
      ctx,
      call,
      args,
      command: 'copy $from -> $to',
      op: CopyPathOp(from, to, overwrite: overwrite),
      background: false,
      presetRunId: runId,
    );
    if (!result.isError) {
      await _recordCopy(ctx, runId, to, before, fileExisted: target != null);
    }
    return result;
  }

  /// Создание каталога. Откат каталога не поддерживается changeset'ом.
  Future<ToolResult> _makeDir(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final path = _resolve(ctx, toolStringArg(args, 'path'));
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, 'mkdir denied by policy');
    }
    final existed = await _statOrNull(ctx, path) != null;
    final runId = ToolExecutor._uuid.v4();
    if (decision == PolicyDecision.ask) {
      final approved = await _approve(
        ctx,
        call,
        args,
        runId: runId,
        command: 'mkdir $path',
        summary: path,
        reason: 'create directory',
      );
      if (!approved.allowed) {
        return _rejected(path, reason: approved.reason);
      }
    }
    final result = await _exec(
      ctx,
      call,
      args,
      command: 'mkdir $path',
      op: MakeDirOp(path),
      background: false,
      presetRunId: runId,
    );
    if (!result.isError && !existed) {
      await _recordUnrecoverable(ctx, runId);
    }
    return result;
  }

  Future<StatResult?> _statOrNull(ToolContext ctx, String path) async {
    final run = await captureOp(ctx.runtime, StatOp(path));
    return run.ok ? StatResult.parse(run.stdout) : null;
  }

  Future<String?> _readTextOrNull(ToolContext ctx, String path) async {
    final run = await captureOp(ctx.runtime, ReadRawOp(path));
    return run.ok ? run.stdout : null;
  }

  Future<void> _recordDelete(
    ToolContext ctx,
    String runId,
    String path,
    String? before,
  ) async {
    final turnId = ctx.turnUserMessageId;
    if (turnId == null) return;
    if (before == null || before.contains('\uFFFD')) {
      await _recordUnrecoverable(ctx, runId);
      return;
    }
    await _changesets.recordSuccessfulDelete(
      chatId: ctx.chat.id,
      turnId: turnId,
      path: path,
      beforeText: before,
    );
  }

  Future<void> _recordCopy(
    ToolContext ctx,
    String runId,
    String path,
    String? before, {
    required bool fileExisted,
  }) async {
    final turnId = ctx.turnUserMessageId;
    if (turnId == null) return;
    if (fileExisted && (before == null || before.contains('\uFFFD'))) {
      await _recordUnrecoverable(ctx, runId);
      return;
    }
    await _changesets.recordSuccessfulWrite(
      chatId: ctx.chat.id,
      turnId: turnId,
      path: path,
      fileExisted: fileExisted,
      beforeText: before ?? '',
    );
  }

  Future<void> _recordUnrecoverable(ToolContext ctx, String runId) async {
    final turnId = ctx.turnUserMessageId;
    if (turnId == null) return;
    await _changesets.recordUnrecoverable(
      chatId: ctx.chat.id,
      turnId: turnId,
      toolRunId: runId,
    );
  }

  /// Запись нового содержимого. [expectedMtime] — mtime файла до чтения ([_mtimeOrNull]); null — файла не было.
  /// Проверка mtime выполняется на Host непосредственно перед записью, уже после подтверждения пользователя.
  Future<ToolResult> _mutateFile(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args, {
    required String path,
    required String before,
    required String after,
    required String? expectedMtime,
  }) async {
    final diff = _renderDiff(before, after);
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, 'write denied by policy');
    }
    // Один id на всю жизнь записи: ожидание подтверждения и выполнение — одна строка в журнале.
    // Бэкап привязан к нему: предыдущие версии не затираются при повторной записи.
    final runId = ToolExecutor._uuid.v4();
    final turnId = ctx.turnUserMessageId;
    if (decision == PolicyDecision.ask) {
      final approved = await _approve(
        ctx,
        call,
        args,
        runId: runId,
        command: 'write $path',
        summary: path,
        reason: 'write operation',
        diff: diff,
      );
      if (!approved.allowed) {
        return _rejected(path, reason: approved.reason);
      }
    }
    final backupPath = turnId == null
        ? '$path.pw-bak-$runId'
        : await _changesets.prepareHostWriteBackupPath(
            hostKind: ctx.host.kind,
            chatId: ctx.chat.id,
            turnId: turnId,
            targetPath: path,
            toolRunId: runId,
          );
    final result = await _exec(
      ctx,
      call,
      args,
      command: 'write $path',
      op: WriteFileOp(
        path,
        backupPath: backupPath,
        expectedMtime: expectedMtime,
      ),
      background: false,
      presetRunId: runId,
      stdin: Uint8List.fromList(utf8.encode(after)),
    );
    await _recordSuccessfulWriteIfNeeded(
      ctx,
      result,
      path: path,
      before: before,
      fileExisted: expectedMtime != null,
    );
    return result;
  }

  /// Manifest и backup в store — только после успешной записи на Host.
  Future<void> _recordSuccessfulWriteIfNeeded(
    ToolContext ctx,
    ToolResult result, {
    required String path,
    required String before,
    required bool fileExisted,
  }) async {
    final turnId = ctx.turnUserMessageId;
    if (turnId == null || result.isError) return;
    await _changesets.recordSuccessfulWrite(
      chatId: ctx.chat.id,
      turnId: turnId,
      path: path,
      fileExisted: fileExisted,
      beforeText: before,
    );
  }

  Future<ToolResult> _askUser(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final question = toolStringArg(args, 'question');
    final run = _newRun(
      ctx,
      ToolExecutor._uuid.v4(),
      call,
      args,
      ToolRunStatus.waitingUser,
    );
    await _saveRun(run);
    final answer = await _broker.askUser(ctx.chat.id, run.id, question);
    return _finishQuestion(run, answer);
  }
}
