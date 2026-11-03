import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/session_state.dart';
import 'package:probably_works/agent/exec/command_executor.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/policy/policy_engine.dart';
import 'package:probably_works/agent/skills/builtin_skills.dart';
import 'package:probably_works/agent/state/session_state_service.dart';
import 'package:probably_works/agent/tools/self_tool_handler.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/agent/workspace/workspace_context_loader.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/ansi_text.dart';
import 'package:probably_works/core/util/char_substring.dart';
import 'package:probably_works/core/util/line_diff.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/shell_adapter.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:uuid/uuid.dart';

/// Контекст одного запуска инструмента: чат, Host с рантаймом и политика.
class ToolContext {
  const ToolContext({
    required this.chat,
    required this.messageId,
    required this.host,
    required this.runtime,
    required this.limits,
    required this.policy,
    required this.onBackgroundDone,
  });

  final Chat chat;
  final String messageId;
  final Host host;
  final HostRuntime runtime;
  final AppLimits limits;
  final PolicyEngine policy;

  /// Вызывается, когда фоновая команда завершилась (после записи ToolRun).
  final void Function(ToolRun run, ExecOutcome outcome) onBackgroundDone;
}

class ToolResult {
  const ToolResult(this.text, {this.isError = false, this.finish = false});

  /// Текст для модели (role tool).
  final String text;
  final bool isError;

  /// `finish` завершает ход агента.
  final bool finish;
}

/// Исполняет вызовы инструментов модели: Policy → approve → выполнение → ToolRun.
@lazySingleton
class ToolExecutor {
  ToolExecutor(
    this._chats,
    this._commands,
    this._broker,
    this._state,
    this._workspace,
    this._self,
  );

  final ChatRepository _chats;
  final CommandExecutor _commands;
  final InteractionBroker _broker;
  final SessionStateService _state;
  final WorkspaceContextLoader _workspace;
  final SelfToolHandler _self;

  /// Self-инструменты, которые только читают (выполняются сразу, без подтверждения).
  static const _selfReadTools = {
    ToolNames.hostList,
    ToolNames.settingsRead,
    ToolNames.hostTest,
    ToolNames.hostDiagnose,
  };

  static const _uuid = Uuid();

  static const _maxDiffLines = 200;

  static const _defaultReadLines = 200;
  static const _maxReadLines = 1000;
  static const _minReadChunkBytes = 64;

  final _runChanges = StreamController<ToolRun>.broadcast();

  /// Каждое сохранение ToolRun: UI и сессия получают изменения статуса без опроса БД.
  Stream<ToolRun> get runChanges => _runChanges.stream;

  Future<void> _saveRun(ToolRun run) async {
    await _chats.saveToolRun(run);
    if (!_runChanges.isClosed) _runChanges.add(run);
  }

  Future<ToolResult> execute(LlmToolCall call, ToolContext ctx) async {
    final Map<String, dynamic> args;
    try {
      args = call.arguments.trim().isEmpty
          ? {}
          : jsonDecode(call.arguments) as Map<String, dynamic>;
    } on FormatException catch (error) {
      return ToolResult(
        'invalid arguments JSON: ${error.message}',
        isError: true,
      );
    } on TypeError {
      return const ToolResult(
        'invalid arguments: expected a JSON object',
        isError: true,
      );
    }
    try {
      return await switch (call.name) {
        ToolNames.hostInfo => _hostCommand(
          ctx,
          call,
          args,
          ShellAdapter(ctx.host.os).hostInfo(),
        ),
        ToolNames.listDir => _hostCommand(
          ctx,
          call,
          args,
          ShellAdapter(ctx.host.os).listDir(_resolve(ctx, _str(args, 'path'))),
        ),
        ToolNames.readFile => _readFile(ctx, call, args),
        ToolNames.grep => _hostCommand(
          ctx,
          call,
          args,
          ShellAdapter(ctx.host.os)
              .grep(_str(args, 'pattern'), _resolve(ctx, _str(args, 'path'))),
        ),
        ToolNames.which => _hostCommand(
          ctx,
          call,
          args,
          ShellAdapter(ctx.host.os).which(_str(args, 'name')),
        ),
        ToolNames.runCommand => _runCommand(ctx, call, args),
        ToolNames.writeFile => _writeFile(ctx, call, args),
        ToolNames.editFile => _editFile(ctx, call, args),
        ToolNames.askUser => _askUser(ctx, call, args),
        ToolNames.finish => Future.value(
          ToolResult(_str(args, 'summary'), finish: true),
        ),
        ToolNames.setGoal ||
        ToolNames.updatePlan ||
        ToolNames.pinFact ||
        ToolNames.unpinFact ||
        ToolNames.listStateRevisions ||
        ToolNames.getStateRevision ||
        ToolNames.chatHistorySearch ||
        ToolNames.listSkills ||
        ToolNames.loadSkill => _stateTool(ctx, call, args),
        ToolNames.hostList ||
        ToolNames.hostAdd ||
        ToolNames.hostUpdate ||
        ToolNames.hostTest ||
        ToolNames.hostDiagnose ||
        ToolNames.settingsRead ||
        ToolNames.settingsUpdate => _selfTool(ctx, call, args),
        _ => Future.value(
          ToolResult('unknown tool: ${call.name}', isError: true),
        ),
      };
    } on ArgumentError catch (error) {
      return ToolResult('invalid arguments: ${error.message}', isError: true);
    } on TypeError {
      return ToolResult(
        'invalid argument types for ${call.name}',
        isError: true,
      );
    }
  }

  // ---- read_file -----------------------------------------------------------

  /// Чтение по строкам: курсор offset/byte_offset, лимиты строк и байтов из [AppLimits].
  /// Размер чанка не превышает половины лимита вывода для модели, иначе [TextClip] вырежет середину.
  Future<ToolResult> _readFile(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) {
    final chunk = math.min(
      math.max(ctx.limits.readFileChunkBytes, _minReadChunkBytes),
      ctx.limits.toolOutputForModelChars ~/ 2,
    );
    return _hostCommand(
      ctx,
      call,
      args,
      ShellAdapter(ctx.host.os).readFile(
        _resolve(ctx, _str(args, 'path')),
        offset: _intArg(args, 'offset', min: 1, fallback: 1),
        byteOffset: _intArg(args, 'byte_offset', min: 0, fallback: 0),
        limit: _intArg(
          args,
          'limit',
          min: 1,
          max: _maxReadLines,
          fallback: _defaultReadLines,
        ),
        chunkBytes: chunk,
        lineBytes: ctx.limits.readFileLineBytes,
      ),
    );
  }

  // ---- host commands -----------------------------------------------------

  Future<ToolResult> _hostCommand(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    String command,
  ) {
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, ctx.policy.reasonFor(call.name, args));
    }
    return _exec(ctx, call, args, command: command, background: false);
  }

  Future<ToolResult> _runCommand(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final command = _str(args, 'command');
    final background = args['background'] == true;
    final cwdArg = args['cwd'] as String?;
    // Относительный cwd считается от workspace, как и пути остальных инструментов.
    final cwd = cwdArg == null || cwdArg.isEmpty
        ? ctx.chat.workspace
        : _resolve(ctx, cwdArg);
    // Один id на всю жизнь команды: ожидание подтверждения и выполнение — одна строка в журнале.
    final runId = _uuid.v4();
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
        if (!approved) return _rejected(command);
        break;
      case PolicyDecision.allow:
        break;
    }
    return _exec(
      ctx,
      call,
      args,
      command: command,
      cwd: cwd,
      background: background,
      presetRunId: runId,
      inTerminal: true,
    );
  }

  Future<ToolResult> _writeFile(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final path = _resolve(ctx, _str(args, 'path'));
    final content = _str(args, 'content');
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
    final run = await captureRun(
      ctx.runtime,
      ShellAdapter(ctx.host.os).statMtime(path),
    );
    final value = run.stdout.trim();
    return run.ok && value.isNotEmpty ? value : null;
  }

  Future<ToolResult> _editFile(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final path = _resolve(ctx, _str(args, 'path'));
    final oldString = _str(args, 'old_string');
    final newString = _str(args, 'new_string');
    final replaceAll = args['replace_all'] == true;
    // mtime снимается раньше содержимого: если файл изменится между ними, защита записи это заметит.
    final mtime = await _mtimeOrNull(ctx, path);
    final read = await captureRun(
      ctx.runtime,
      ShellAdapter(ctx.host.os).readFileOrEmpty(path),
    );
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
    final runId = _uuid.v4();
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
      if (!approved) return _rejected(path);
    }
    final command = ShellAdapter(ctx.host.os).writeFile(
      path,
      backupPath: '$path.pw-bak-$runId',
      expectedMtime: expectedMtime,
    );
    return _exec(
      ctx,
      call,
      args,
      command: command,
      background: false,
      displayCommand: 'write $path',
      presetRunId: runId,
      stdin: Uint8List.fromList(utf8.encode(after)),
    );
  }

  Future<ToolResult> _askUser(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final question = _str(args, 'question');
    final runId = _uuid.v4();
    final run = _newRun(ctx, runId, call, args, ToolRunStatus.waitingUser);
    await _saveRun(run);
    final answer = await _broker.askUser(ctx.chat.id, runId, question);
    final text = answer ?? 'User did not answer (the turn was stopped).';
    await _saveRun(
      run.copyWith(
        status: ToolRunStatus.done,
        finishedAt: DateTime.now(),
        resultPreview: _preview(text),
      ),
    );
    return ToolResult(answer == null ? text : 'User answered: $answer');
  }

  // ---- state tools -------------------------------------------------------

  Future<ToolResult> _stateTool(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final chat = await _chats.chat(ctx.chat.id) ?? ctx.chat;
    switch (call.name) {
      case ToolNames.setGoal:
        final goal = _str(args, 'goal');
        await _state.mutate(chat, (rev) => rev.goal = goal);
        return const ToolResult('goal saved');
      case ToolNames.updatePlan:
        final items = [
          for (final item in (args['items'] as List? ?? const []))
            PlanItem(
              id: (item as Map)['id'] as String,
              text: item['text'] as String,
              status: PlanItemStatus.values.byName(
                item['status'] as String? ?? 'pending',
              ),
            ),
        ];
        await _state.mutate(chat, (rev) {
          rev
            ..plan = items
            ..taskStatus = items.isEmpty ? TaskStatus.idle : TaskStatus.active;
        });
        return ToolResult('plan updated: ${items.length} items');
      case ToolNames.pinFact:
        final fact = PinnedFact(
          id: charPrefix(_uuid.v4(), 8),
          text: _str(args, 'text'),
          createdAt: DateTime.now(),
        );
        await _state.mutate(
          chat,
          (rev) => rev.pinnedFacts = [...rev.pinnedFacts, fact],
        );
        return ToolResult('pinned fact ${fact.id}');
      case ToolNames.unpinFact:
        final id = _str(args, 'id');
        await _state.mutate(
          chat,
          (rev) =>
              rev.pinnedFacts = [...rev.pinnedFacts]
                ..removeWhere((f) => f.id == id),
        );
        return ToolResult('unpinned fact $id');
      case ToolNames.listStateRevisions:
        final lines = await _state.sealedIndex(chat.id);
        return ToolResult(
          lines.isEmpty ? 'no earlier revisions' : lines.join('\n'),
        );
      case ToolNames.getStateRevision:
        final revision = await _chats.revision(_str(args, 'id'));
        if (revision == null ||
            revision.chatId != chat.id ||
            !revision.sealed) {
          return const ToolResult(
            'sealed revision not found in this chat',
            isError: true,
          );
        }
        return ToolResult(
          jsonEncode({
            'id': revision.id,
            'parentId': revision.parentId,
            ...revision.stateToJson(),
          }),
        );
      case ToolNames.chatHistorySearch:
        final found = await _chats.searchMessages(chat.id, _str(args, 'query'));
        if (found.isEmpty) return const ToolResult('no matches');
        return ToolResult(
          [
            for (final m in found)
              '#${m.seq} ${m.role.name}: ${_preview(m.text, max: 300)}',
          ].join('\n'),
        );
      case ToolNames.listSkills:
        final snapshot = await _workspace.load(chat, ctx.runtime, ctx.host.os);
        final skills = BuiltinSkills.catalog(
          snapshot.needsTrust ? const [] : snapshot.skills,
        );
        final note = snapshot.needsTrust
            ? '\nworkspace skills are unavailable until the workspace is trusted'
            : '';
        return ToolResult(
          [for (final s in skills) '${s.name}: ${s.description}'].join('\n') +
              note,
        );
      case ToolNames.loadSkill:
        final name = _str(args, 'name');
        final builtin = BuiltinSkills.byName(name);
        if (builtin != null) {
          // Загрузка открывает self-инструменты до конца чата (см. SessionStateRevision.unlockedSkills).
          await _state.mutate(chat, (rev) => rev.unlockedSkills.add(name));
          return ToolResult(builtin.body);
        }
        final snapshot = await _workspace.load(chat, ctx.runtime, ctx.host.os);
        final skill = snapshot.skills.where((s) => s.name == name).firstOrNull;
        if (skill == null) {
          return ToolResult('skill not found: $name', isError: true);
        }
        final body = await _workspace.loadSkillBody(
          ctx.runtime,
          skill,
          ctx.host.os,
        );
        return body == null
            ? ToolResult('cannot read skill $name', isError: true)
            : ToolResult(body);
    }
    return ToolResult('unknown state tool: ${call.name}', isError: true);
  }

  // ---- self tools --------------------------------------------------------

  /// Self-инструменты доступны только после загрузки встроенного скилла в этом чате.
  /// Проверка здесь, а не только в списке инструментов: модель может вызвать инструмент из истории.
  Future<ToolResult> _selfTool(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final chat = await _chats.chat(ctx.chat.id) ?? ctx.chat;
    final state = await _state.current(chat);
    if (!state.unlockedSkills.contains(BuiltinSkills.probablyWorks.name)) {
      return ToolResult(
        '${call.name} is not available: load the skill '
        '"${BuiltinSkills.probablyWorks.name}" first',
        isError: true,
      );
    }
    if (_selfReadTools.contains(call.name)) {
      return ToolResult(await _self.read(call.name, args));
    }
    return _selfWrite(ctx, call, args);
  }

  Future<ToolResult> _selfWrite(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final change = await _self.prepare(call.name, args);
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, 'denied by policy');
    }
    final bool needsApproval;
    final String reason;
    final keyPath = change.keyPath;
    if (keyPath != null) {
      // Путь к ключу, который назвал пользователь, — его команда: подтверждение не нужно ни в Ask, ни в YOLO.
      // Путь, найденный агентом, может оказаться не тем ключом: спрашиваем всегда.
      final named = await _keyPathNamedByUser(ctx.chat.id, keyPath);
      needsApproval = !named;
      reason = 'key path was found by the agent, not named by you';
    } else {
      needsApproval = decision == PolicyDecision.ask;
      reason = ctx.policy.reasonFor(call.name, args);
    }
    // Один id на всю жизнь записи: карточка подтверждения и итоговая строка журнала.
    final runId = _uuid.v4();
    if (needsApproval) {
      final approved = await _approve(
        ctx,
        call,
        args,
        runId: runId,
        summary: change.summary,
        command: change.summary,
        reason: reason,
      );
      if (!approved) return _rejected(change.summary);
    }
    final String text;
    try {
      text = await change.apply();
    } on Object catch (error) {
      return ToolResult('${call.name} failed: $error', isError: true);
    }
    await _saveRun(
      _newRun(
        ctx,
        runId,
        call,
        args,
        ToolRunStatus.done,
        command: change.summary,
        finishedAt: DateTime.now(),
      ).copyWith(resultPreview: _preview(text)),
    );
    return ToolResult(text);
  }

  /// Дословное вхождение пути в сообщения пользователя этого чата. Текст модели и файлов сюда не входит.
  Future<bool> _keyPathNamedByUser(String chatId, String keyPath) async {
    final messages = await _chats.messages(chatId);
    return messages.any(
      (message) =>
          message.role == MessageRole.user && message.text.contains(keyPath),
    );
  }

  // ---- execution core ----------------------------------------------------

  Future<ToolResult> _exec(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args, {
    required String command,
    required bool background,
    String? cwd,
    String? displayCommand,
    String? presetRunId,
    bool inTerminal = false,
    Uint8List? stdin,
  }) async {
    final runId = presetRunId ?? _uuid.v4();
    var run = _newRun(
      ctx,
      runId,
      call,
      args,
      ToolRunStatus.running,
      command: displayCommand ?? command,
      background: background,
    );
    await _saveRun(run);

    final handle = await _commands.start(
      chatId: ctx.chat.id,
      hostId: ctx.host.id,
      toolCallId: runId,
      runtime: ctx.runtime,
      command: command,
      cwd: cwd,
      limits: ctx.limits,
      background: background,
      inTerminal: inTerminal,
      stdin: stdin,
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
      unawaited(() async {
        final outcome = await handle.finished;
        final finished = await _complete(run, outcome);
        ctx.onBackgroundDone(finished, outcome);
      }());
      return ToolResult(
        'started in background (run $runId, pid $pid). You will be notified when it finishes.',
      );
    }

    final outcome = await handle.finished;
    final finished = await _complete(run, outcome);
    return ToolResult(
      _modelText(outcome, ctx.limits, finished.id),
      isError: outcome.status != ToolRunStatus.done,
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
      resultPreview: _preview(
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

  // ---- helpers -----------------------------------------------------------

  Future<bool> _approve(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args, {
    required String runId,
    required String summary,
    required String reason,
    String? command,
    String? diff,
  }) async {
    final run = _newRun(
      ctx,
      runId,
      call,
      args,
      ToolRunStatus.waitingApproval,
      command: command,
    );
    await _saveRun(run);
    final allowed = await _broker.requestApproval(
      ApprovalRequest(
        id: runId,
        chatId: ctx.chat.id,
        toolName: call.name,
        summary: summary,
        reason: reason,
        diff: diff,
      ),
    );
    if (!allowed) {
      await _saveRun(
        run.copyWith(status: ToolRunStatus.denied, finishedAt: DateTime.now()),
      );
    }
    return allowed;
  }

  Future<ToolResult> _denied(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    String reason,
  ) async {
    final run = _newRun(
      ctx,
      _uuid.v4(),
      call,
      args,
      ToolRunStatus.denied,
      finishedAt: DateTime.now(),
    );
    await _saveRun(run.copyWith(resultPreview: reason));
    return ToolResult('denied by policy: $reason', isError: true);
  }

  ToolResult _rejected(String target) => ToolResult(
    'the user rejected this action ($target). Do not retry it without a different approach.',
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
  }) => ToolRun(
    id: runId,
    chatId: ctx.chat.id,
    messageId: ctx.messageId,
    toolName: call.name,
    argsJson: call.arguments,
    command:
        command ??
        (call.name == ToolNames.runCommand ? _str(args, 'command') : null),
    background: background,
    status: status,
    startedAt: DateTime.now(),
    finishedAt: finishedAt,
  );

  String _resolve(ToolContext ctx, String path) {
    if (path.startsWith('/') ||
        path.startsWith('~') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) {
      return path;
    }
    final workspace = ctx.chat.workspace;
    if (workspace == null || workspace.isEmpty) return path;
    return '$workspace/$path';
  }

  Future<String> _readOrEmpty(ToolContext ctx, String path) async {
    final read = await captureRun(
      ctx.runtime,
      ShellAdapter(ctx.host.os).readFileOrEmpty(path),
    );
    return read.ok ? read.stdout : '';
  }

  String _renderDiff(String before, String after) {
    final lines = LineDiff.compute(before, after);
    final buffer = StringBuffer();
    var count = 0;
    for (final line in lines) {
      if (line.kind == DiffKind.same) continue;
      if (count++ >= _maxDiffLines) {
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

  static String _preview(String text, {int max = 200}) {
    final single = plainTerminalText(text)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return single.length <= max ? single : '${charPrefix(single, max)}…';
  }

  static String _str(Map<String, dynamic> args, String key) {
    final value = args[key];
    if (value is! String || value.isEmpty) {
      throw ArgumentError.value(value, key, 'required string');
    }
    return value;
  }

  /// Необязательное целое. Дробные значения и значения ниже [min] — ошибка аргумента, а не молчаливая подмена.
  static int _intArg(
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
