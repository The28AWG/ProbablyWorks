part of 'tool_executor.dart';

/// Сколько символов вывода отдаётся по умолчанию. Меньше, чем у read_file:
/// прочитанный текст остаётся в истории хода и тратит окно модели.
const _defaultRunOutputChars = 8000;

/// Потолок одного чтения. Больше не полезно: столько же максимум отдаётся
/// модели за один инструментальный вызов.
const _maxRunOutputChars = 60000;

/// Сколько символов одной строки показывает grep: длинные JSON-логи не должны
/// съедать весь лимит ответа.
const _grepLineChars = 500;

/// Максимум строк окружения вокруг совпадения.
const _grepContextMax = 50;

/// Максимум совпадений за один вызов grep.
const _grepMatchesMax = 200;

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

  /// Чтение сохранённого вывода запуска. Хранится только хвост, как в
  /// терминале: `tail` показывает конец, `chunk` читает по точному смещению,
  /// `grep` ищет строки с окружением. Пока команда идёт, читается живой хвост
  /// из памяти: полный текст появится в БД только после финала.
  Future<ToolResult> _readRunOutput(
    ToolContext ctx,
    Map<String, dynamic> args,
  ) async {
    final id = toolStringArg(args, 'run_id');
    final run = await _chats.toolRun(id);
    if (run == null || run.chatId != ctx.chat.id) {
      return ToolResult('run not found in this chat: $id', isError: true);
    }
    final mode = _runOutputMode(args);
    final limit = _intArg(
      args,
      'limit',
      min: 1,
      max: _maxRunOutputChars,
      fallback: _defaultRunOutputChars,
    );
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
    return switch (mode) {
      'grep' => _grepRunOutput(args, text, header, limit),
      'chunk' => _chunkRunOutput(args, text, header, limit),
      _ => _tailRunOutput(text, header, limit),
    };
  }

  /// Общие поля ответа для любого режима чтения.
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

  String _runOutputMode(Map<String, dynamic> args) {
    final value = args['mode'];
    if (value == null) return 'tail';
    if (value is! String || !const {'tail', 'chunk', 'grep'}.contains(value)) {
      throw ArgumentError.value(value, 'mode', 'tail, chunk or grep expected');
    }
    return value;
  }

  /// Последние [limit] символов. Смещение отдаётся явно, чтобы можно было
  /// продолжить вглубь через `mode=chunk`.
  ToolResult _tailRunOutput(String text, List<String> header, int limit) {
    final total = text.characters.length;
    final start = total > limit ? total - limit : 0;
    final body = charFrom(text, start);
    header
      ..add('start_offset: $start')
      ..add('total: $total chars');
    final nav = start > 0
        ? '[earlier output: mode=chunk offset=${math.max(0, start - limit)} '
              'limit=$limit]'
        : '[start of retained output]';
    return ToolResult('${header.join('\n')}\n\n$body\n\n$nav');
  }

  /// Окно [limit] символов с точного смещения [offset].
  ToolResult _chunkRunOutput(
    Map<String, dynamic> args,
    String text,
    List<String> header,
    int limit,
  ) {
    final offset = _intArg(args, 'offset', min: 0, fallback: 0);
    final total = text.characters.length;
    if (offset >= total) {
      header.add('offset $offset is past the end ($total chars)');
      return ToolResult(header.join('\n'));
    }
    final body = charPrefix(charFrom(text, offset), limit);
    final next = offset + body.characters.length;
    header
      ..add('offset: $offset')
      ..add('total: $total chars');
    final nav = next < total
        ? '[more: continue with mode=chunk offset=$next limit=$limit]'
        : '[end]';
    return ToolResult('${header.join('\n')}\n\n$body\n\n$nav');
  }

  /// Поиск по строкам. Совпадение отдаётся с окружением и точным смещением:
  /// по нему можно перейти в `mode=chunk` и прочитать окно целиком.
  ToolResult _grepRunOutput(
    Map<String, dynamic> args,
    String text,
    List<String> header,
    int limit,
  ) {
    final pattern = toolStringArg(args, 'pattern');
    final regex = args['regex'] != false;
    final ignoreCase = args['ignore_case'] == true;
    final context = _intArg(
      args,
      'context',
      min: 0,
      max: _grepContextMax,
      fallback: 2,
    );
    final maxMatches = _intArg(
      args,
      'max_matches',
      min: 1,
      max: _grepMatchesMax,
      fallback: 30,
    );
    final matchOffset = _intArg(args, 'match_offset', min: 0, fallback: 0);
    final RegExp expression;
    try {
      expression = RegExp(
        regex ? pattern : RegExp.escape(pattern),
        caseSensitive: !ignoreCase,
      );
    } on FormatException catch (error) {
      return ToolResult('invalid pattern: ${error.message}', isError: true);
    }
    final lines = text.split('\n');
    // Смещения считаются в символах, как их принимает mode=chunk: та же
    // единица, что отдаёт charFrom/charPrefix.
    final starts = <int>[];
    var position = 0;
    for (final line in lines) {
      starts.add(position);
      position += line.characters.length + 1;
    }
    final hits = <int>[];
    for (var i = 0; i < lines.length; i++) {
      // ANSI-последовательности не должны мешать ни шаблону, ни чтению.
      if (expression.hasMatch(plainTerminalText(lines[i]))) hits.add(i);
    }
    header
      ..add(
        'pattern: ${jsonEncode(pattern)} '
        '(${regex ? 'regex' : 'literal'}, '
        '${ignoreCase ? 'case-insensitive' : 'case-sensitive'})',
      )
      ..add('matches: ${hits.length}');
    if (hits.isEmpty) {
      header.add(
        'no matches; try ignore_case, regex=false or a shorter pattern',
      );
      return ToolResult(header.join('\n'));
    }
    if (matchOffset >= hits.length) {
      header.add('match_offset $matchOffset is past the last match');
      return ToolResult(header.join('\n'));
    }
    final groups = <String>[];
    var covered = 0;
    var length = 0;
    var cut = false;
    var index = matchOffset;
    while (index < hits.length && covered < maxMatches) {
      final match = hits[index];
      final first = math.max(0, match - context);
      var last = math.min(lines.length - 1, match + context);
      final matchLines = <int>{match};
      var scan = index + 1;
      // Пересекающиеся или соседние окружения склеиваются: иначе следующая
      // страница повторила бы те же строки как контекст.
      while (scan < hits.length) {
        final next = hits[scan];
        if (next - context > last + 1) break;
        matchLines.add(next);
        last = math.max(last, math.min(lines.length - 1, next + context));
        scan++;
      }
      final group = _grepGroup(lines, starts, matchLines, first, last);
      if (groups.isEmpty && group.characters.length > limit) {
        // Даже один фрагмент не влез: отдаём начало и честно предупреждаем.
        groups.add(charPrefix(group, limit));
        cut = true;
        covered = scan - matchOffset;
        break;
      }
      if (length + group.characters.length > limit) break;
      groups.add(group);
      length += group.characters.length + 4;
      covered = scan - matchOffset;
      index = scan;
    }
    header.add('showing: ${matchOffset + 1}-${matchOffset + covered}');
    final next = matchOffset + covered;
    final nav = [
      if (cut) '[cut by the character limit; narrow the pattern]',
      if (next < hits.length) '[more matches: match_offset=$next]' else '[end]',
    ].join('\n');
    return ToolResult(
      '${header.join('\n')}\n\n${groups.join('\n--\n')}\n\n$nav',
    );
  }

  /// Одна группа строк с пометкой совпадений и смещением начала каждой строки.
  String _grepGroup(
    List<String> lines,
    List<int> starts,
    Set<int> matchLines,
    int first,
    int last,
  ) {
    final buffer = StringBuffer();
    for (var i = first; i <= last; i++) {
      if (buffer.isNotEmpty) buffer.writeln();
      final plain = plainTerminalText(lines[i]);
      final shown = plain.characters.length > _grepLineChars
          ? '${charPrefix(plain, _grepLineChars)}…'
          : plain;
      buffer.write(
        matchLines.contains(i)
            ? '[line ${i + 1}, offset ${starts[i]}] $shown'
            : '[line ${i + 1}] $shown',
      );
    }
    return buffer.toString();
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
