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
          run.resultError ? 'error' : 'ok',
          run.toolName,
          run.background ? 'background' : 'foreground',
          output == null
              ? (run.isActive ? 'live-tail' : 'no-output')
              : 'output ${output.characters.length} chars'
                    '${run.outputTruncated ? ' (tail kept)' : ''}',
          Redactor.redact(run.command ?? ''),
        ].join(' | '),
      );
    }
    if (sorted.length > 100) {
      lines.add('[more runs not shown: ${sorted.length - 100}]');
    }
    return ToolResult(lines.join('\n'));
  }

  /// Чтение сохранённого длинного текста: вывода запуска или вложения сообщения.
  ///
  /// Источник выбирается аргументом: `run_id` — хвост вывода запуска,
  /// `attachment` — текст файла, приложенного к сообщению этого чата. Режимы и
  /// формат ответа общие (`tail`, `chunk`, `grep`), см. [ToolOutputReader].
  Future<ToolResult> _readRunOutput(
    ToolContext ctx,
    Map<String, dynamic> args,
  ) async {
    final attachment = args['attachment'];
    final runId = args['run_id'];
    if (attachment != null && runId != null) {
      return const ToolResult(
        'pass either run_id or attachment, not both',
        isError: true,
      );
    }
    if (attachment != null) {
      if (attachment is! String || attachment.isEmpty) {
        throw ArgumentError.value(attachment, 'attachment', 'string expected');
      }
      return _readAttachment(ctx, attachment, args);
    }
    if (runId is! String || runId.isEmpty) {
      return const ToolResult(
        'pass run_id (output of a tool run) or attachment '
        '(text of a file attached to a message)',
        isError: true,
      );
    }
    final run = await _chats.toolRun(runId);
    if (run == null || run.chatId != ctx.chat.id) {
      return ToolResult('run not found in this chat: $runId', isError: true);
    }
    // Пока запуск активен, outputText ещё не записан: читаем кольцевой буфер
    // живого вывода. Он ограничен, поэтому это подсказка, а не полный лог.
    final stored = run.outputText;
    final live = stored == null || stored.isEmpty
        ? _commands.liveTail(run.id)
        : null;
    final text = stored == null || stored.isEmpty ? (live ?? '') : stored;
    final header = _runOutputHeader(run, text: text, live: live != null);
    if (text.isEmpty) {
      header.add(
        run.isActive
            ? 'output is not available yet: the run is active and has printed '
                  'nothing'
            : 'no output',
      );
      return ToolResult(header.join('\n'));
    }
    return ToolOutputReader('read_run_output run_id=${run.id}')
        .read(args, text, header);
  }

  /// Текст вложения из сообщений **этого** чата.
  ///
  /// Изоляция — общее правило для всех инструментов, которые читают результат
  /// чужой работы: источник ищется только среди сообщений своего чата, а
  /// `message_id` проверяется внутри этого набора. Отдельный запрос по id
  /// сообщения открыл бы вложение соседнего чата.
  Future<ToolResult> _readAttachment(
    ToolContext ctx,
    String name,
    Map<String, dynamic> args,
  ) async {
    final messageId = args['message_id'];
    if (messageId != null && messageId is! String) {
      throw ArgumentError.value(messageId, 'message_id', 'string expected');
    }
    final messages = await _chats.messages(ctx.chat.id);
    final found = findAttachment(messages, name, messageId: messageId);
    if (found == null) {
      return ToolResult(
        'attachment not found in this chat: $name. '
        'Use the exact name shown in the message; message_id narrows the '
        'search when names repeat.',
        isError: true,
      );
    }
    final attachment = found.attachment;
    final owner = found.message;
    final content = attachment.content;
    if (content == null || content.isEmpty) {
      // Бинарный файл идёт модели отдельной частью и текстом не читается.
      return ToolResult(
        'attachment ${attachment.name} has no text: '
        '${attachment.mimeType ?? 'binary content'} is sent to the model as a '
        'content part and cannot be read as text',
        isError: true,
      );
    }
    final text = Redactor.redact(content);
    final header = [
      'attachment: ${attachment.name}',
      if (attachment.mimeType != null) 'type: ${attachment.mimeType}',
      'size: ${attachment.sizeBytes} bytes',
      'message: ${owner.id}',
    ];
    // Имя в подсказке квотируется: оно может содержать пробелы, и скопированная
    // строка должна остаться одним аргументом.
    final target =
        'read_run_output attachment=${jsonEncode(attachment.name)} '
        'message_id=${owner.id}';
    return ToolOutputReader(target).read(args, text, header);
  }

  /// Общие поля ответа для любого режима чтения запуска.
  List<String> _runOutputHeader(
    ToolRun run, {
    required String text,
    required bool live,
  }) => [
    'run_id: ${run.id}',
    'status: ${run.status.name}',
    if (run.resultError) 'result: error',
    if (run.exitCode != null) 'exit_code: ${run.exitCode}',
    'tool: ${run.toolName}',
    if (run.command != null) 'command: ${Redactor.redact(run.command!)}',
    'output: ${text.characters.length} chars',
    if (run.outputTruncated) 'retention: tail only (earlier output dropped)',
    if (live)
      'source: live tail of an active run; offsets shift as output arrives',
  ];

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
        ToolRunStatus.done,
        command: 'stop run $id',
        finishedAt: DateTime.now(),
      ).copyWith(
        resultError: !stopped,
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
