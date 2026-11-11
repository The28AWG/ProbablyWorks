import 'dart:async';

import 'package:logging/logging.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/loop/agent_event.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:uuid/uuid.dart';

/// Состояние фонового субагента.
enum SubagentStatus { running, completed, failed, stopped }

/// Запущенный субагент. [id] — id его скрытого чата.
final class SubagentRun {
  SubagentRun({
    required this.id,
    required this.parentChatId,
    required this.rootChatId,
    required this.task,
    required this.model,
  });

  final String id;
  final String parentChatId;
  final String rootChatId;
  final String task;
  final String model;
  final Completer<SubagentResult> completer = Completer();

  SubagentStatus status = SubagentStatus.running;
  SubagentResult? result;

  /// Результат уже забрали через `wait_subagent`.
  bool awaited = false;

  /// Результат уже отправлен событием в root-чат.
  bool delivered = false;
}

/// Итог субагента для родительского инструмента.
final class SubagentResult {
  const SubagentResult({
    required this.text,
    required this.status,
    this.isError = false,
  });

  final String text;
  final SubagentStatus status;
  final bool isError;
}

/// Запускает скрытые чаты субагентов и ждёт их результатов.
final class SubagentManager {
  SubagentManager(this._hub);

  static const _maxDepth = 8;
  static final _uuid = Uuid();
  static final _log = Logger('SubagentManager');

  final AgentHub _hub;
  final _runs = <String, SubagentRun>{};
  final _subscriptions = <String, StreamSubscription<AgentEvent>>{};

  SubagentRun? run(String id) => _runs[id];

  /// Активные субагенты, запущенные из [chatId].
  List<SubagentRun> activeFor(String chatId) => [
    for (final run in _runs.values)
      if (run.parentChatId == chatId && run.status == SubagentStatus.running)
        run,
  ];

  /// Создаёт скрытый чат и запускает в нём ход с [task].
  Future<SubagentRun> start({
    required Chat parent,
    required String task,
    String? modelStrategy,
  }) async {
    final trimmed = task.trim();
    if (trimmed.isEmpty) throw ArgumentError('subagent task is empty');
    final root = parent.rootChatId ?? parent.id;
    final depth = parent.depth + 1;
    if (depth > _maxDepth) {
      throw StateError('subagent depth limit reached');
    }
    final model = await _resolveModel(parent, modelStrategy);
    final id = _uuid.v4();
    final now = DateTime.now();
    await _hub.chats.saveChat(
      Chat(
        id: id,
        hostId: parent.hostId,
        kind: ChatKind.subagent,
        parentChatId: parent.id,
        rootChatId: root,
        depth: depth,
        projectId: parent.projectId,
        title: TextClip.headTail(trimmed, maxChars: 80),
        titleSource: ChatTitleSource.user,
        model: model,
        policyMode: parent.policyMode,
        workspace: parent.workspace,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final run = SubagentRun(
      id: id,
      parentChatId: parent.id,
      rootChatId: root,
      task: trimmed,
      model: model,
    );
    _runs[id] = run;
    final session = _hub.session(id);
    _subscriptions[id] = session.events.listen((event) {
      if (event is AgentTurnFinished && event.chatId == id) {
        unawaited(_complete(run, event.end));
      }
    });
    try {
      unawaited(session.submit(trimmed));
    } on Object catch (error) {
      await _complete(run, TurnEnd.failed, error: '$error');
    }
    return run;
  }

  /// Ждёт завершения субагента и помечает результат как полученный через инструмент.
  Future<SubagentResult> wait(String runId) async {
    final run = _runs[runId];
    if (run == null) throw StateError('unknown subagent: $runId');
    run.awaited = true;
    return run.completer.future;
  }

  /// Останавливает субагента.
  Future<void> stop(String runId) async {
    final run = _runs[runId];
    if (run == null) return;
    await _hub.session(runId).stop();
  }

  /// Останавливает всех активных детей [chatId]. Вызывается при Stop родителя.
  Future<void> stopChildren(String chatId) async {
    for (final run in activeFor(chatId)) {
      await _hub.session(run.id).stop();
    }
  }

  Future<String> _resolveModel(Chat parent, String? strategy) async {
    if (strategy != null &&
        strategy.isNotEmpty &&
        strategy != 'parent' &&
        strategy != 'default') {
      throw StateError('subagent model must be parent or default');
    }
    final defaultModel =
        await _hub.settings.read(SettingsRepository.keyDefaultModel) ?? '';
    final parentModel = parent.model?.isNotEmpty == true
        ? parent.model!
        : defaultModel;
    final configured =
        await _hub.settings.read(SettingsRepository.keySubagentModel) ?? '';
    final chosen = strategy == 'parent'
        ? parentModel
        : configured.isNotEmpty
        ? configured
        : parentModel;
    if (chosen.isEmpty) throw StateError('subagent model is not set');
    final live = _hub.models.state.modelOf(chosen);
    final saved = _hub.models.state.saved[chosen];
    if (live == null && saved == null) {
      throw StateError('subagent model is unavailable: $chosen');
    }
    if (!(live?.supportsTools ?? saved?.supportsTools ?? false)) {
      throw StateError('subagent model has no tool calling: $chosen');
    }
    return chosen;
  }

  Future<void> _complete(SubagentRun run, TurnEnd end, {String? error}) async {
    if (run.completer.isCompleted) return;
    final status = switch (end) {
      TurnEnd.completed => SubagentStatus.completed,
      TurnEnd.stopped => SubagentStatus.stopped,
      TurnEnd.failed || TurnEnd.stepLimit => SubagentStatus.failed,
    };
    final text = error ?? await _lastAssistantText(run.id);
    final result = SubagentResult(
      text: text.isEmpty ? 'subagent finished without a text result' : text,
      status: status,
      isError: status == SubagentStatus.failed,
    );
    run
      ..status = status
      ..result = result;
    if (!run.completer.isCompleted) run.completer.complete(result);
    await _subscriptions.remove(run.id)?.cancel();
    await _aggregateUsage(run);
    if (!run.awaited) {
      run.delivered = true;
      await _hub.session(run.rootChatId).deliverEvent(_eventText(run, result));
    }
  }

  Future<String> _lastAssistantText(String chatId) async {
    final messages = await _hub.chats.messages(chatId);
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message.role == MessageRole.assistant &&
          message.text.trim().isNotEmpty) {
        return message.text.trim();
      }
    }
    return '';
  }

  Future<void> _aggregateUsage(SubagentRun run) async {
    try {
      final usage = await _hub.settings.readDailyUsage(run.id);
      if (usage.requests == 0) return;
      await _hub.settings.addDailyUsage(
        run.rootChatId,
        promptTokens: usage.promptTokens,
        completionTokens: usage.completionTokens,
        costUsd: usage.costUsd,
      );
    } on Object catch (error) {
      _log.warning('cannot aggregate subagent usage', error);
    }
  }

  static String _eventText(SubagentRun run, SubagentResult result) =>
      'Subagent ${run.id} finished with status ${result.status.name}.\n'
      'Task: ${run.task}\n'
      'Model: ${run.model}\n'
      '${TextClip.headTail(result.text, maxChars: 4000)}';
}
