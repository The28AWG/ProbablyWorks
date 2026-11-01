import 'dart:async';
import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/session_state.dart';
import 'package:probably_works/agent/exec/command_executor.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/policy/policy_engine.dart';
import 'package:probably_works/agent/state/session_state_service.dart';
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
  );

  final ChatRepository _chats;
  final CommandExecutor _commands;
  final InteractionBroker _broker;
  final SessionStateService _state;
  final WorkspaceContextLoader _workspace;

  static const _uuid = Uuid();

  static const _maxDiffLines = 200;

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
        ToolNames.readFile => _hostCommand(
          ctx,
          call,
          args,
          ShellAdapter(ctx.host.os).readFile(
            _resolve(ctx, _str(args, 'path')),
            maxBytes: (args['max_bytes'] as num?)?.toInt() ?? 20000,
          ),
        ),
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
        _ => Future.value(
          ToolResult('unknown tool: ${call.name}', isError: true),
        ),
      };
    } on ArgumentError catch (error) {
      return ToolResult('invalid arguments: ${error.message}', isError: true);
    }
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
    final cwd = (args['cwd'] as String?) ?? ctx.chat.workspace;
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
    final before = await _readOrEmpty(ctx, path);
    return _mutateFile(
      ctx,
      call,
      args,
      path: path,
      before: before,
      after: content,
    );
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
    final read = await captureRun(
      ctx.runtime,
      ShellAdapter(ctx.host.os).readFileOrEmpty(path),
    );
    if (!read.ok) {
      return ToolResult(
        'cannot read $path (file missing or unreadable)',
        isError: true,
      );
    }
    final before = read.stdout;
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
    );
  }

  Future<ToolResult> _mutateFile(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args, {
    required String path,
    required String before,
    required String after,
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
    final command = ShellAdapter(ctx.host.os)
        .writeFile(path, after, backupPath: '$path.pw-bak-$runId');
    return _exec(
      ctx,
      call,
      args,
      command: command,
      background: false,
      displayCommand: 'write $path',
      presetRunId: runId,
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
        if (snapshot.needsTrust) {
          return const ToolResult(
            'workspace is not trusted yet; skills are unavailable',
            isError: true,
          );
        }
        if (snapshot.skills.isEmpty) return const ToolResult('no skills found');
        return ToolResult(
          [for (final s in snapshot.skills) '${s.name}: ${s.description}']
              .join('\n'),
        );
      case ToolNames.loadSkill:
        final name = _str(args, 'name');
        final snapshot = await _workspace.load(chat, ctx.runtime, ctx.host.os);
        final skill = snapshot.skills.where((s) => s.name == name).firstOrNull;
        if (skill == null) {
          return ToolResult('skill not found: $name', isError: true);
        }
        final body = await _workspace.loadSkillBody(ctx.runtime, skill);
        return body == null
            ? ToolResult('cannot read skill $name', isError: true)
            : ToolResult(body);
    }
    return ToolResult('unknown state tool: ${call.name}', isError: true);
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
}
