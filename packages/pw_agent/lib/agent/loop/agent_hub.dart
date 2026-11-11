import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/context/context_builder.dart';
import 'package:pw_agent/agent/context/context_compactor.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/session_state.dart';
import 'package:pw_agent/agent/exec/active_exec_registry.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/chat_session.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/agent/plugins/plugin_service.dart';
import 'package:pw_agent/agent/project/project_lifecycle.dart';
import 'package:pw_agent/agent/state/session_state_service.dart';
import 'package:pw_agent/agent/subagent/subagent_manager.dart';
import 'package:pw_agent/agent/subagent/subagent_tool_source.dart';
import 'package:pw_agent/agent/tools/tool_executor.dart';
import 'package:pw_agent/agent/turn/turn_changeset_service.dart';
import 'package:pw_agent/agent/workspace/workspace_context_loader.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/policy_profile_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/notify/app_notifier.dart';
import 'package:pw_agent/host/host_runtime_factory.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:uuid/uuid.dart';

/// Точка входа агента: зависимости хода и одна сессия на чат.
/// Сессии живут, пока работает приложение: фоновые команды доставляют результаты в свой чат.
@singleton
class AgentHub {
  AgentHub(
    this.chats,
    this.settings,
    this.hosts,
    this.runtimes,
    this.llm,
    this.models,
    this.builder,
    this.compactor,
    this.tools,
    this.mcp,
    this.plugins,
    this.workspace,
    this.state,
    this.broker,
    this.registry,
    this.logs,
    this.turnChangesets,
    this.notifier,
    this.projects,
    this.projectStore,
    this.policyProfiles,
  ) {
    final manager = SubagentManager(this);
    subagents = manager;
    tools
      ..registerToolSource(DelegateTaskToolSource(manager))
      ..registerToolSource(WaitSubagentToolSource(manager));
  }

  final ChatRepository chats;
  final SettingsRepository settings;
  final HostRepository hosts;
  final HostRuntimeFactory runtimes;
  final LlmProvider llm;
  final ModelCatalogService models;
  final ContextBuilder builder;
  final ContextCompactor compactor;
  final ToolExecutor tools;
  final McpService mcp;
  final PluginService plugins;
  final WorkspaceContextLoader workspace;

  /// Скрытые чаты субагентов и их фоновые результаты.
  late final SubagentManager subagents;
  final SessionStateService state;
  final InteractionBroker broker;
  final ActiveExecRegistry registry;
  final ExecLogStore logs;
  final TurnChangesetService turnChangesets;
  final AppNotifier notifier;

  /// Жизненный цикл проекта: создание, перенос чата, архив и окончательное удаление.
  final ProjectLifecycleService projects;

  /// Строки проектов, факты и доверие skills.
  final ProjectRepository projectStore;
  final PolicyProfileRepository policyProfiles;

  final Map<String, ChatSession> _sessions = {};

  final _allEvents = StreamController<AgentEvent>.broadcast();

  /// События всех сессий в одном потоке (для списка чатов: активность, бейджи).
  Stream<AgentEvent> get allEvents => _allEvents.stream;

  /// Продолжает незакрытые шаги после старта приложения.
  ///
  /// Карточки подтверждения и вопросов не регистрируются: их покажет открытие
  /// чата. Вызов, которому карточка не нужна, выполняется сразу. Прерванный
  /// процесс заново не запускается.
  Future<void> resumeAfterRestart() async {
    await subagents.restore();
    for (final id in await chats.chatIds()) {
      if (!await ChatSession.hasUnfinishedStep(chats, id)) continue;
      await session(id).resumeAfterRestart();
    }
  }

  /// Чаты, в которых сейчас идёт ход.
  Set<String> get runningChatIds => {
    for (final session in _sessions.values)
      if (session.isRunning) session.chatId,
  };

  ChatSession session(String chatId) => _sessions.putIfAbsent(chatId, () {
    final created = ChatSession(chatId, this);
    created.events.listen(_allEvents.add);
    return created;
  });

  Future<AppLimits> limits() => settings.limits();

  static const _uuid = Uuid();

  /// Форк чата до завершённого ответа [untilMessageId].
  ///
  /// Без [untilMessageId] копируется вся история. С ним — только сообщения до
  /// указанного ответа включительно; состояние берётся из ревизии последнего
  /// пользовательского сообщения этого отрезка. Файлы на Host не копируются
  /// и не откатываются: оба чата смотрят на текущую рабочую папку.
  Future<Chat> forkChat(
    String chatId, {
    String? title,
    String? untilMessageId,
  }) async {
    final source = await chats.chat(chatId);
    if (source == null) {
      throw ArgumentError.value(chatId, 'chatId', 'chat not found');
    }
    var messages = await chats.messages(chatId);
    if (untilMessageId != null) {
      final index = messages.indexWhere(
        (message) => message.id == untilMessageId,
      );
      if (index < 0) {
        throw ArgumentError.value(
          untilMessageId,
          'untilMessageId',
          'message not found in this chat',
        );
      }
      messages = messages.sublist(0, index + 1);
    }
    final messageIds = <String, String>{
      for (final message in messages) message.id: _uuid.v4(),
    };
    final runs = await chats.toolRunsForChat(chatId);
    ChatMessage? lastUser;
    for (final message in messages) {
      if (message.role == MessageRole.user) lastUser = message;
    }
    final sourceRevisionId = lastUser?.openedRevisionId;
    final savedRevision = sourceRevisionId == null
        ? null
        : await chats.revision(sourceRevisionId);
    final sourceState = savedRevision ?? await state.current(source);
    final id = _uuid.v4();
    final revisionId = _uuid.v4();
    final now = DateTime.now();
    final copy = Chat(
      id: id,
      hostId: source.hostId,
      projectId: source.projectId,
      title: title?.trim().isNotEmpty == true ? title!.trim() : source.title,
      titleSource: ChatTitleSource.user,
      model: source.model,
      policyMode: source.policyMode,
      workspace: source.workspace,
      lastPromptTokens: source.lastPromptTokens,
      lastCompletionTokens: source.lastCompletionTokens,
      contextLength: source.contextLength,
      currentRevisionId: revisionId,
      createdAt: now,
      updatedAt: now,
    );
    await chats.saveChat(copy);
    await chats.saveRevision(
      SessionStateRevision(
        id: revisionId,
        chatId: id,
        createdAt: now,
        goal: sourceState.goal,
        taskStatus: sourceState.taskStatus,
        plan: [...sourceState.plan],
        pinnedFacts: [...sourceState.pinnedFacts],
      ),
    );

    for (final message in messages) {
      final messageId = messageIds[message.id]!;
      await chats.insertMessage(
        ChatMessage(
          id: messageId,
          chatId: id,
          seq: message.seq,
          role: message.role,
          createdAt: message.createdAt,
          text: message.text,
          reasoning: message.reasoning,
          toolCalls: message.toolCalls,
          toolCallId: message.toolCallId,
          attachments: message.attachments,
        ),
      );
    }
    for (final run in runs) {
      // Ожидающие и активные запуски в новый чат не переносятся: ответ на
      // карточку принадлежит исходному ходу.
      if (run.isActive) continue;
      final messageId = messageIds[run.messageId];
      if (messageId == null) continue;
      await chats.saveToolRun(
        ToolRun(
          id: _uuid.v4(),
          chatId: id,
          messageId: messageId,
          toolName: run.toolName,
          argsJson: run.argsJson,
          command: run.command,
          background: run.background,
          status: run.status,
          startedAt: run.startedAt,
          finishedAt: run.finishedAt,
          exitCode: run.exitCode,
          timedOut: run.timedOut,
          outputText: run.outputText,
          outputTruncated: run.outputTruncated,
          resultPreview: run.resultPreview,
          toolCallId: run.toolCallId,
        ),
      );
    }
    return copy;
  }

  /// Новый пустой чат на Host, сразу записанный в БД; политика — из настроек по умолчанию.
  /// Проект появляется только вместе с явной папкой чата или папкой хоста.
  Future<Chat> newChat({required String hostId}) async {
    final host = await hosts.byId(hostId);
    var chat = draftChat(hostId: hostId, host: host);
    chat = await projects.attach(chat);
    await chats.saveChat(chat);
    return chat;
  }

  /// Чат на Host, который ещё не записан в БД: появится в списке с первым сообщением.
  /// Политика берётся из памяти настроек, поэтому чат создаётся синхронно (см. [SettingsRepository.preload]).
  ///
  /// Рабочая папка — только та, что задана хосту. Дом сюда не подставляется:
  /// иначе каждый новый чат входил бы в домашний проект.
  Chat draftChat({required String hostId, Host? host}) {
    final now = DateTime.now();
    final policy = PolicyMode.values.byName(
      settings.cached(SettingsRepository.keyDefaultPolicy) ?? 'ask',
    );
    return Chat(
      id: _uuid.v4(),
      hostId: hostId,
      workspace: host == null ? null : projects.configuredWorkspace(host),
      title: '',
      createdAt: now,
      updatedAt: now,
      policyMode: policy,
    );
  }
}
