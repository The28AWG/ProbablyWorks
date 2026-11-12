import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/session_state.dart';
import 'package:pw_agent/agent/exec/command_executor.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/policy/policy_engine.dart';
import 'package:pw_agent/agent/skills/builtin_skills.dart';
import 'package:pw_agent/agent/state/session_state_service.dart';
import 'package:pw_agent/agent/tools/self_tool_handler.dart';
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
  ) : _registry = ToolRegistry();

  final ChatRepository _chats;
  final CommandExecutor _commands;
  final InteractionBroker _broker;
  final SessionStateService _state;
  final WorkspaceContextLoader _workspace;
  final SelfToolHandler _self;
  final ProjectRepository _projects;
  final TurnChangesetService _changesets;
  final ToolRegistry _registry;

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
      return await switch (call.name) {
        ToolNames.hostInfo => _hostOp(ctx, call, args, const HostInfoOp()),
        ToolNames.listDir => _hostOp(
          ctx,
          call,
          args,
          ListDirOp(_resolve(ctx, _str(args, 'path'))),
        ),
        ToolNames.readFile => _readFile(ctx, call, args),
        ToolNames.grep => _hostOp(
          ctx,
          call,
          args,
          GrepOp(_str(args, 'pattern'), _resolve(ctx, _str(args, 'path'))),
        ),
        ToolNames.which => _hostOp(
          ctx,
          call,
          args,
          WhichOp(_str(args, 'name')),
        ),
        ToolNames.runCommand => _runCommand(ctx, call, args),
        ToolNames.writeFile => _writeFile(ctx, call, args),
        ToolNames.editFile => _editFile(ctx, call, args),
        ToolNames.applyPatch => _applyPatch(ctx, call, args),
        ToolNames.deleteFile => _deleteFile(ctx, call, args),
        ToolNames.movePath => _movePath(ctx, call, args),
        ToolNames.copyPath => _copyPath(ctx, call, args),
        ToolNames.makeDir => _makeDir(ctx, call, args),
        ToolNames.statPath => _hostOp(
          ctx,
          call,
          args,
          StatOp(_resolve(ctx, _str(args, 'path'))),
        ),
        ToolNames.glob => _hostOp(
          ctx,
          call,
          args,
          GlobOp(_str(args, 'pattern'), _resolve(ctx, _str(args, 'path'))),
        ),
        ToolNames.askUser => _askUser(ctx, call, args),
        ToolNames.finish => Future.value(
          ToolResult(_str(args, 'summary'), finish: true),
        ),
        ToolNames.listRuns => _listRuns(ctx),
        ToolNames.readRunOutput => _readRunOutput(ctx, args),
        ToolNames.stopRun => _stopRun(ctx, call, args),
        ToolNames.setGoal ||
        ToolNames.updatePlan ||
        ToolNames.pinFact ||
        ToolNames.unpinFact ||
        ToolNames.listStateRevisions ||
        ToolNames.getStateRevision ||
        ToolNames.chatHistorySearch ||
        ToolNames.listSkills ||
        ToolNames.loadSkill => _stateTool(ctx, call, args),
        ToolNames.pinProjectFact ||
        ToolNames.unpinProjectFact => _projectFact(ctx, call, args),
        ToolNames.hostList ||
        ToolNames.hostAdd ||
        ToolNames.hostUpdate ||
        ToolNames.hostTest ||
        ToolNames.hostDiagnose ||
        ToolNames.settingsRead ||
        ToolNames.settingsUpdate => _selfTool(ctx, call, args),
        _ => _externalTool(ctx, call, args),
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
    final path = _resolve(ctx, _str(args, 'path'));
    return _hostOp(
      ctx,
      call,
      args,
      ReadFileOp(
        path,
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

  /// Служебная операция Host: политика, затем выполнение через рантайм. Команды в журнале нет,
  /// поэтому в журнал и шаг идёт подпись операции [HostOp.label].
  Future<ToolResult> _hostOp(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    HostOp op,
  ) {
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, ctx.policy.reasonFor(call.name, args));
    }
    return _exec(ctx, call, args, command: op.label, op: op, background: false);
  }

  Future<ToolResult> _runCommand(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final command = _str(args, 'command');
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
    final run = await captureOp(ctx.runtime, StatOp(path));
    if (!run.ok) return null;
    return StatResult.parse(run.stdout)?.mtime;
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
    final path = _resolve(ctx, _str(args, 'path'));
    final raw = _str(args, 'patch');
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
    final path = _resolve(ctx, _str(args, 'path'));
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
    final runId = _uuid.v4();
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
    final from = _resolve(ctx, _str(args, 'from'));
    final to = _resolve(ctx, _str(args, 'to'));
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
    final runId = _uuid.v4();
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
    final from = _resolve(ctx, _str(args, 'from'));
    final to = _resolve(ctx, _str(args, 'to'));
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
    final runId = _uuid.v4();
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
    final path = _resolve(ctx, _str(args, 'path'));
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, 'mkdir denied by policy');
    }
    final existed = await _statOrNull(ctx, path) != null;
    final runId = _uuid.v4();
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
    final runId = _uuid.v4();
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
    final question = _str(args, 'question');
    final run = _newRun(ctx, _uuid.v4(), call, args, ToolRunStatus.waitingUser);
    await _saveRun(run);
    final answer = await _broker.askUser(ctx.chat.id, run.id, question);
    return _finishQuestion(run, answer);
  }

  // ---- project facts -----------------------------------------------------

  /// Общая память проекта. Карточка подтверждения обязательна даже в YOLO:
  /// факт увидят все чаты проекта, поэтому решение не должно быть побочным эффектом.
  Future<ToolResult> _projectFact(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
    final project = ctx.project;
    if (project == null) {
      return const ToolResult(
        'this chat has no project yet; project facts are unavailable',
        isError: true,
      );
    }
    final pin = call.name == ToolNames.pinProjectFact;
    final text = pin ? _str(args, 'text').trim() : '';
    final factId = pin ? '' : _str(args, 'id');
    if (pin && text.isEmpty) {
      return const ToolResult('fact text is empty', isError: true);
    }
    if (!pin) {
      final fact = await _projects.fact(factId);
      if (fact == null || fact.projectId != project.id) {
        return ToolResult('project fact not found: $factId', isError: true);
      }
    }
    final summary = pin
        ? 'Save project fact: $text'
        : 'Remove project fact $factId';
    final runId = _uuid.v4();
    final approved = await _approve(
      ctx,
      call,
      args,
      runId: runId,
      summary: summary,
      command: summary,
      reason: ctx.policy.reasonFor(call.name, args),
      allowStoredGrant: false,
    );
    if (!approved.allowed) {
      return _rejected(summary, reason: approved.reason);
    }
    return _applyProjectFact(
      ctx,
      call,
      args,
      runId: runId,
      pin: pin,
      startedAt: DateTime.now(),
    );
  }

  Future<ToolResult> _resumeProjectFact(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    ToolRun run,
  ) => _applyProjectFact(
    ctx,
    call,
    args,
    runId: run.id,
    pin: call.name == ToolNames.pinProjectFact,
    startedAt: run.startedAt,
  );

  Future<ToolResult> _applyProjectFact(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args, {
    required String runId,
    required bool pin,
    required DateTime startedAt,
  }) async {
    final project = ctx.project;
    if (project == null) {
      return const ToolResult('this chat has no project', isError: true);
    }
    final String summary;
    if (pin) {
      final fact = ProjectFact(
        id: _uuid.v4(),
        projectId: project.id,
        text: _str(args, 'text').trim(),
        createdAt: DateTime.now(),
      );
      try {
        await _projects.addFact(fact);
      } on Object catch (error) {
        return ToolResult('cannot save project fact: $error', isError: true);
      }
      summary = 'project fact ${fact.id} saved';
    } else {
      final id = _str(args, 'id');
      await _projects.deleteFact(id);
      summary = 'project fact $id removed';
    }
    final run = _newRun(
      ctx,
      runId,
      call,
      args,
      ToolRunStatus.done,
      command: summary,
      startedAt: startedAt,
      finishedAt: DateTime.now(),
    ).copyWith(resultPreview: summary, clearPendingCard: true);
    await _saveRun(run);
    return ToolResult(summary);
  }

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
    final id = _str(args, 'run_id');
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
    final id = _str(args, 'run_id');
    final run = await _chats.toolRun(id);
    if (run == null || run.chatId != ctx.chat.id) {
      return ToolResult('run not found in this chat: $id', isError: true);
    }
    final decision = ctx.policy.decide(call.name, args);
    if (decision == PolicyDecision.deny) {
      return _denied(ctx, call, args, 'stop denied by policy');
    }
    final runId = _uuid.v4();
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
        final query = _str(args, 'query');
        final scope = _str(args, 'scope');
        if (scope.isEmpty || scope == 'chat') {
          final found = await _chats.searchMessages(chat.id, query);
          if (found.isEmpty) return const ToolResult('no matches');
          return ToolResult(
            [
              for (final m in found)
                '#${m.seq} ${m.role.name}: ${_preview(m.text, max: 300)}',
            ].join('\n'),
          );
        }
        if (scope != 'project' && scope != 'all') {
          return const ToolResult(
            'scope must be chat, project or all',
            isError: true,
          );
        }
        final projectId = scope == 'project' ? ctx.project?.id : null;
        if (scope == 'project' && projectId == null) {
          return const ToolResult(
            'this chat has no project; project search is unavailable',
            isError: true,
          );
        }
        final found = await _chats.searchMessagesAll(
          query,
          projectId: projectId,
        );
        if (found.isEmpty) return const ToolResult('no matches');
        return ToolResult(
          [
            for (final hit in found)
              '${hit.chatTitle} #${hit.message.seq} ${hit.message.role.name}: ${_preview(hit.message.text, max: 300)}',
          ].join('\n'),
        );
      case ToolNames.listSkills:
        final trusted = ctx.project == null
            ? const <String>{}
            : await _projects.trustedSkillNames(ctx.project!.id);
        final snapshot = await _workspace.load(
          chat,
          ctx.runtime,
          project: ctx.project,
          trustedSkills: trusted,
        );
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
        if (builtin != null) return ToolResult(builtin.body);
        final trusted = ctx.project == null
            ? const <String>{}
            : await _projects.trustedSkillNames(ctx.project!.id);
        final snapshot = await _workspace.load(
          chat,
          ctx.runtime,
          project: ctx.project,
          trustedSkills: trusted,
        );
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

  // ---- self tools --------------------------------------------------------

  Future<ToolResult> _selfTool(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
  ) async {
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
    // Лимиты меняют поведение самого агента: таймауты, параллелизм, размер контекста
    // и число шагов. Даже в авто-подтверждении это решение пользователя, а не побочный
    // эффект задачи.
    final limitsChange =
        call.name == ToolNames.settingsUpdate &&
        args['key'] == SettingsRepository.keyLimits;
    if (limitsChange) {
      needsApproval = true;
      reason = 'operational limits change how the agent runs';
    } else if (keyPath != null) {
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
        allowStoredGrant: !limitsChange,
      );
      if (!approved.allowed) {
        return _rejected(change.summary, reason: approved.reason);
      }
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
    final runId = presetRunId ?? _uuid.v4();
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

  /// Ждёт ответ. Карточка уже зарегистрирована вызовом брокера до этого будущего.
  Future<WaitingDecision> _asQuestion(Future<String?> pending) async =>
      WaitingDecision.question(await pending);

  /// Ждёт подтверждение, не откладывая регистрацию карточки.
  Future<WaitingDecision> _asApproval(Future<ApprovalDecision> pending) async =>
      WaitingDecision.approval(await pending);

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

  Future<ToolResult> _finishQuestion(ToolRun run, String? answer) async {
    final text = answer ?? 'User did not answer (the turn was stopped).';
    await _saveRun(
      run.copyWith(
        status: ToolRunStatus.done,
        finishedAt: DateTime.now(),
        resultPreview: _preview(text),
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
        resultPreview: _preview(text),
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
  ) => switch (call.name) {
    ToolNames.runCommand => _resumeCommand(ctx, call, args, run),
    ToolNames.writeFile => _resumeWrite(ctx, call, args, run),
    ToolNames.editFile => _resumeEdit(ctx, call, args, run),
    ToolNames.hostAdd ||
    ToolNames.hostUpdate ||
    ToolNames.settingsUpdate => _resumeSelf(ctx, call, args, run),
    ToolNames.pinProjectFact ||
    ToolNames.unpinProjectFact => _resumeProjectFact(ctx, call, args, run),
    _ => _failRun(run, 'cannot resume ${call.name}'),
  };

  Future<ToolResult> _resumeCommand(
    ToolContext ctx,
    LlmToolCall call,
    Map<String, dynamic> args,
    ToolRun run,
  ) {
    final command = _str(args, 'command');
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
    final path = _resolve(ctx, _str(args, 'path'));
    final content = _str(args, 'content');
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
    final path = _resolve(ctx, _str(args, 'path'));
    final oldString = _str(args, 'old_string');
    final newString = _str(args, 'new_string');
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
          resultPreview: _preview(text),
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
      _uuid.v4(),
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
        (call.name == ToolNames.runCommand ? _str(args, 'command') : null),
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
  static String _withCommandDefaults(ToolContext ctx, String command) {
    if (ctx.runtime.os == HostOs.windows) return command;
    const prefix =
        r'export PAGER="${PAGER:-cat}" GIT_PAGER="${GIT_PAGER:-cat}" '
        r'CI="${CI:-1}"; ';
    return '$prefix$command';
  }

  /// Необязательный stdin. Пустая строка — явный EOF, отсутствие ключа — PTY.
  static Uint8List? _stdinArg(Map<String, dynamic> args) {
    if (!args.containsKey('stdin')) return null;
    final value = args['stdin'];
    if (value is! String) {
      throw ArgumentError.value(value, 'stdin', 'string expected');
    }
    return Uint8List.fromList(utf8.encode(value));
  }

  /// Таймаут конкретной команды. Не даёт обойти лимиты из Settings: запрошенное
  /// значение ограничено тем же пределом, что и обычный запуск.
  static Duration? _timeoutArg(
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
