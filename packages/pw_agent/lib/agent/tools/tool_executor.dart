import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/exec/command_executor.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/policy/policy_engine.dart';
import 'package:pw_agent/agent/policy/sensitive_paths.dart';
import 'package:pw_agent/agent/state/session_state_service.dart';
import 'package:pw_agent/agent/tools/self_tool_catalog.dart';
import 'package:pw_agent/agent/tools/self_tool_handler.dart';
import 'package:pw_agent/agent/tools/state_tool_handler.dart';
import 'package:pw_agent/agent/tools/tool_args.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/agent/tools/tool_effect.dart';
import 'package:pw_agent/agent/tools/tool_registry.dart';
import 'package:pw_agent/agent/tools/tool_source.dart';
import 'package:pw_agent/agent/tools/tool_types.dart';
import 'package:pw_agent/agent/turn/host_write_backup_path.dart';
import 'package:pw_agent/agent/turn/turn_changeset_service.dart';
import 'package:pw_agent/agent/workspace/workspace_context_loader.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/util/ansi_text.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/core/util/line_diff.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/core/util/shell_quote.dart';
import 'package:pw_agent/core/util/text_clip.dart';
import 'package:pw_agent/core/util/unified_diff.dart';
import 'package:pw_agent/core/util/workspace_path.dart';
import 'package:pw_agent/host/host_capture.dart';
import 'package:pw_agent/host/host_op.dart';
import 'package:pw_agent/host/shell_adapter.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:uuid/uuid.dart';

export 'package:pw_agent/agent/tools/tool_types.dart';

part 'tool_executor_read.dart';
part 'tool_executor_host.dart';
part 'tool_executor_run.dart';
part 'tool_executor_self.dart';
part 'tool_executor_exec.dart';
part 'tool_executor_helpers.dart';

/// Обработчик встроенного инструмента: policy → approve → выполнение.
typedef _ToolHandler = Future<ToolResult> Function(
  ToolContext ctx,
  LlmToolCall call,
  Map<String, dynamic> args,
);

/// Продолжение уже подтверждённого встроенного инструмента.
typedef _ResumeHandler = Future<ToolResult> Function(
  ToolContext ctx,
  LlmToolCall call,
  Map<String, dynamic> args,
  ToolRun run,
);

/// Ответ на карточку, которую показали снова после перезапуска.
class WaitingDecision {
  /// [text] — ответ на вопрос. null значит, что ход остановили и ответа нет.
  const WaitingDecision.question(this.text) : approval = null;

  /// [approval] — решение по подтверждению, включая область и причину отказа.
  const WaitingDecision.approval(this.approval) : text = null;

  final String? text;
  final ApprovalDecision? approval;

  bool get allowed => approval?.allowed ?? false;
  String? get denyReason => approval?.reason;
}

/// Незавершённый запуск и будущее его решения. Карточка уже лежит в [InteractionBroker].
class ReopenedWait {
  const ReopenedWait(this.run, this.decision);

  final ToolRun run;
  final Future<WaitingDecision> decision;
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
    this._projects,
    this._changesets,
  ) : _registry = ToolRegistry() {
    assert(() {
      final declared = {
        for (final spec in [...ToolCatalog.specs, ...SelfToolCatalog.specs])
          spec.name,
      };
      for (final name in declared) {
        if (!_handlers.containsKey(name)) {
          throw StateError('builtin tool $name has no executor handler');
        }
      }
      for (final name in _handlers.keys) {
        if (!declared.contains(name)) {
          throw StateError('executor handler $name has no catalog spec');
        }
      }
      return true;
    }());
  }

  final ChatRepository _chats;
  final CommandExecutor _commands;
  final InteractionBroker _broker;
  final SessionStateService _state;
  final WorkspaceContextLoader _workspace;
  final SelfToolHandler _self;
  final ProjectRepository _projects;
  final TurnChangesetService _changesets;
  final ToolRegistry _registry;

  /// Инструменты состояния вынесены из исполнителя: policy, подтверждения и
  /// журнал запусков остаются здесь, работа с целью, планом и skills — в нём.
  late final StateToolHandler _stateTools = StateToolHandler(
    _chats,
    _state,
    _projects,
    _workspace,
  );

  /// Диспетчеризация встроенных инструментов. Имя без обработчика считается
  /// внешним и уходит в [ToolRegistry]; для каталога покрытие проверяет assert
  /// в конструкторе.
  late final Map<String, _ToolHandler> _handlers = {
    ToolNames.hostInfo: (ctx, call, args) =>
        _hostOp(ctx, call, args, const HostInfoOp()),
    ToolNames.listDir: _hostRead,
    ToolNames.readFile: _hostRead,
    ToolNames.grep: _hostRead,
    ToolNames.glob: _hostRead,
    ToolNames.statPath: _hostRead,
    ToolNames.which: (ctx, call, args) =>
        _hostOp(ctx, call, args, WhichOp(toolStringArg(args, 'name'))),
    ToolNames.runCommand: _runCommand,
    ToolNames.writeFile: _writeFile,
    ToolNames.editFile: _editFile,
    ToolNames.applyPatch: _applyPatch,
    ToolNames.deleteFile: _deleteFile,
    ToolNames.movePath: _movePath,
    ToolNames.copyPath: _copyPath,
    ToolNames.makeDir: _makeDir,
    ToolNames.askUser: _askUser,
    ToolNames.finish: (_, _, args) async =>
        ToolResult(toolStringArg(args, 'summary'), finish: true),
    ToolNames.listRuns: (ctx, _, _) => _listRuns(ctx),
    ToolNames.readRunOutput: (ctx, _, args) => _readRunOutput(ctx, args),
    ToolNames.stopRun: _stopRun,
    ToolNames.setGoal: _stateTools.call,
    ToolNames.updatePlan: _stateTools.call,
    ToolNames.pinFact: _stateTools.call,
    ToolNames.unpinFact: _stateTools.call,
    ToolNames.listStateRevisions: _stateTools.call,
    ToolNames.getStateRevision: _stateTools.call,
    ToolNames.chatHistorySearch: _stateTools.call,
    ToolNames.listSkills: _stateTools.call,
    ToolNames.loadSkill: _stateTools.call,
    ToolNames.hostList: _selfTool,
    ToolNames.hostAdd: _selfTool,
    ToolNames.hostUpdate: _selfTool,
    ToolNames.hostTest: _selfTool,
    ToolNames.hostDiagnose: _selfTool,
    ToolNames.settingsRead: _selfTool,
    ToolNames.settingsUpdate: _selfTool,
  };

  /// Продолжение после карточки. Для остальных имён подтверждённого
  /// продолжения нет: такой запуск завершается ошибкой, а не повторяется.
  late final Map<String, _ResumeHandler> _resumeHandlers = {
    ToolNames.runCommand: _resumeCommand,
    ToolNames.writeFile: _resumeWrite,
    ToolNames.editFile: _resumeEdit,
    ToolNames.readFile: _resumeHostRead,
    ToolNames.listDir: _resumeHostRead,
    ToolNames.grep: _resumeHostRead,
    ToolNames.glob: _resumeHostRead,
    ToolNames.statPath: _resumeHostRead,
    ToolNames.hostAdd: _resumeSelf,
    ToolNames.hostUpdate: _resumeSelf,
    ToolNames.settingsUpdate: _resumeSelf,
  };

  /// Описания всех доступных инструментов: встроенные и внешние источники.
  List<LlmToolSpec> get specs => _registry.specs;

  /// Подключает внешний источник инструментов. Дубликаты имён запрещены.
  void registerToolSource(ToolSource source) => _registry.register(source);

  /// Отключает внешний источник и убирает его инструменты из следующих запросов.
  void unregisterToolSource(String sourceId) => _registry.unregister(sourceId);

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
      final handler = _handlers[call.name];
      if (handler == null) return await _externalTool(ctx, call, args);
      return await handler(ctx, call, args);
    } on ArgumentError catch (error) {
      return ToolResult('invalid arguments: ${error.message}', isError: true);
    } on TypeError {
      return ToolResult(
        'invalid argument types for ${call.name}',
        isError: true,
      );
    }
  }

  /// Внешний инструмент: тот же policy → approve → ToolRun, что и у встроенных.
  ///
  /// Источник не получает управление, пока политика не разрешила вызов. Ход
  /// помечается неоткатываемым, если источник может менять Host.
  Future<ToolResult> _externalTool(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final source = _registry.sourceFor(call.name);
    if (source == null) {
      return ToolResult('unknown tool: ${call.name}', isError: true);
    }
    final summary = source.summaryFor(call, args);
    final reason = source.reasonFor(call);
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, reason);
    }
    final runId = _uuid.v4();
    if (decision == PolicyDecision.ask) {
      final approved = await _approve(
        ctx,
        call,
        args,
        runId: runId,
        summary: summary,
        reason: reason,
      );
      if (!approved.allowed) {
        return _rejected(summary, reason: approved.reason);
      }
    }

    final run = _newRun(
      ctx,
      runId,
      call,
      args,
      ToolRunStatus.running,
      command: summary,
    );
    await _saveRun(run);
    try {
      final result = await source.call(call, args, ctx);
      final finished = await _complete(
        run,
        ExecOutcome(
          status: result.isError ? ToolRunStatus.failed : ToolRunStatus.done,
          outputText: result.text,
        ),
      );
      await _markExternalMutation(ctx, finished, source);
      return result;
    } on Object catch (error) {
      final finished = await _complete(
        run,
        ExecOutcome(
          status: ToolRunStatus.failed,
          outputText: '${call.name} failed: $error',
        ),
      );
      await _markExternalMutation(ctx, finished, source);
      return ToolResult('${call.name} failed: $error', isError: true);
    }
  }

  Future<void> _markExternalMutation(
    ToolContext ctx,
    ToolRun run,
    ToolSource source,
  ) async {
    final turnId = ctx.turnUserMessageId;
    if (!source.mutatesHost || turnId == null) return;
    await _changesets.recordExternalMutation(
      chatId: ctx.chat.id,
      turnId: turnId,
      toolRunId: run.id,
    );
  }

  /// Снова показывает карточку незавершённого запуска. Регистрация синхронная:
  /// открытие чата может сразу отдать список карточек, не дожидаясь ответа.
  /// Бросает [ArgumentError], если статус не waiting*.
  Future<ReopenedWait> reopenWaiting(ToolRun run) async {
    final chat = await _chats.chat(run.chatId);
    final approvalChatId = chat?.rootChatId ?? run.chatId;
    if (run.status == ToolRunStatus.waitingUser) {
      final pending = _broker.askUser(
        approvalChatId,
        run.id,
        _questionText(run),
      );
      return ReopenedWait(run, _asQuestion(pending));
    }
    if (run.status == ToolRunStatus.waitingApproval) {
      final card = PendingCard.tryDecode(run.pendingCard);
      final pending = _broker.requestApproval(
        ApprovalRequest(
          id: run.id,
          chatId: approvalChatId,
          toolName: run.toolName,
          summary: card?.summary ?? run.command ?? run.toolName,
          reason: card?.reason ?? '',
          diff: card?.diff,
          turnId: card?.turnId,
          permissionKey: card?.permissionKey,
          grantable: card?.grantable ?? true,
        ),
      );
      return ReopenedWait(run, _asApproval(pending));
    }
    throw ArgumentError.value(run.status, 'run.status', 'not waiting');
  }

  /// Записывает ответ и, если действие подтвердили, выполняет его тем же запуском.
  /// [ctx] нужен только для подтверждённой команды или записи. Вопрос и отказ обходятся без него.
  Future<ToolResult> completeWaiting(
    ToolRun run,
    WaitingDecision decision,
    ToolContext? ctx,
  ) async {
    if (run.status == ToolRunStatus.waitingUser) {
      return _finishQuestion(run, decision.text);
    }
    if (run.status != ToolRunStatus.waitingApproval) {
      return ToolResult('run ${run.id} is not waiting', isError: true);
    }
    final summary =
        PendingCard.tryDecode(run.pendingCard)?.summary ??
        run.command ??
        run.toolName;
    if (!decision.allowed) {
      return _denyRun(run, summary, reason: decision.denyReason);
    }
    if (ctx == null) return _failRun(run, 'host not found');
    final args = _decodeArgs(run.argsJson);
    if (args == null) return _failRun(run, 'invalid arguments JSON');
    final call = LlmToolCall(
      id: run.toolCallId ?? run.id,
      name: run.toolName,
      arguments: run.argsJson,
    );
    try {
      return await _executeApproved(ctx, call, args, run);
    } on ArgumentError catch (error) {
      return _failRun(run, 'invalid arguments: ${error.message}');
    }
  }
}
