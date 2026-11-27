import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/chat_run_stopper.dart';
import 'package:pw_agent/agent/attention/chat_attention_service.dart';
import 'package:pw_agent/agent/context/context_builder.dart';
import 'package:pw_agent/agent/context/context_compactor.dart';
import 'package:pw_agent/agent/domain/attention_digest.dart';
import 'package:pw_agent/agent/domain/chat_attention.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/session_state.dart';
import 'package:pw_agent/agent/exec/active_exec_registry.dart';
import 'package:pw_agent/agent/exec/exec_log_store.dart';
import 'package:pw_agent/agent/interaction/interaction_broker.dart';
import 'package:pw_agent/agent/loop/agent_event.dart';
import 'package:pw_agent/agent/loop/chat_session.dart';
import 'package:pw_agent/agent/mcp/mcp_service.dart';
import 'package:pw_agent/agent/memory/project_memory_service.dart';
import 'package:pw_agent/agent/plugins/plugin_service.dart';
import 'package:pw_agent/agent/project/project_lifecycle.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/agent/schedule/scheduled_task_repository.dart';
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
class AgentHub implements ChatRunStopper, SubagentHost {
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
    this.memory,
    this.scheduledTasks,
  ) {
    final manager = SubagentManager(this);
    subagents = manager;
    tools
      ..registerToolSource(DelegateTaskToolSource(manager))
      ..registerToolSource(WaitSubagentToolSource(manager));
  }

  @override
  final ChatRepository chats;
  @override
  final SettingsRepository settings;
  final HostRepository hosts;
  final HostRuntimeFactory runtimes;
  final LlmProvider llm;
  @override
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

  /// Сводка «что требует внимания» по всем чатам. Ленивая инициализация:
  /// сервису нужны репозиторий и брокер, уже переданные в конструктор.
  late final ChatAttentionService attention = ChatAttentionService(
    chats,
    broker,
    notifier: notifier,
  );

  final ActiveExecRegistry registry;
  final ExecLogStore logs;
  final TurnChangesetService turnChangesets;
  final AppNotifier notifier;

  /// Жизненный цикл проекта: создание, перенос чата, архив и окончательное удаление.
  final ProjectLifecycleService projects;

  /// Строки проектов, память и доверие skills.
  final ProjectRepository projectStore;
  final PolicyProfileRepository policyProfiles;

  /// Очередь отложенных задач: форк чата переносит их по выбору пользователя.
  /// Запуск остаётся у планировщика, а не у хаба.
  final ScheduledTaskRepository scheduledTasks;

  /// Автоматическое обновление саммари проекта после хода.
  final ProjectMemoryService memory;

  /// Обновлять ли память проекта после хода.
  ///
  /// Фоновый запускатель планировщика выключает это: он закрывает базу сразу
  /// после хода, а сетевое обновление памяти не укладывается в бюджет фоновой
  /// задачи. Память обновится в следующем обычном ходе.
  bool memoryUpdatesEnabled = true;

  final Map<String, ChatSession> _sessions = {};

  /// Время последнего обращения к сессии. Нужен для LRU-вытеснения.
  final Map<String, DateTime> _sessionTouched = {};

  /// Сессии без наблюдателей вытесняются после простоя; лимит ограничивает
  /// память, даже если чатов открывали много и подряд.
  static const maxCachedSessions = 32;
  static const sessionIdleAfter = Duration(minutes: 30);

  final _allEvents = StreamController<AgentEvent>.broadcast();

  /// События всех сессий в одном потоке (для списка чатов: активность, бейджи).
  Stream<AgentEvent> get allEvents => _allEvents.stream;

  /// Продолжает незакрытые шаги после старта приложения.
  ///
  /// Карточки подтверждения и вопросов не регистрируются: их покажет открытие
  /// чата. Вызов, которому карточка не нужна, выполняется сразу. Прерванный
  /// процесс заново не запускается.
  Future<void> resumeAfterRestart() async {
    // Внимание и отложенные напоминания запускаются сразу: срок мог истечь,
    // пока приложение было выключено, и напоминание должно уйти даже в демоне
    // без подключённых окон.
    attention.start();
    await subagents.restore();
    for (final id in await chats.chatIds()) {
      if (!await ChatSession.hasUnfinishedStep(chats, id)) continue;
      await session(id).resumeAfterRestart();
    }
  }

  /// Чаты с неотвеченными карточками.
  Set<String> get waitingChatIds => broker.waitingChatIds;

  /// Останавливает ход в чате, если он идёт.
  ///
  /// Не создаёт сессию для чата, которого нет в памяти: очистка истории
  /// удаляет старые записи, и лишний объект ей не нужен.
  @override
  Future<void> stopChat(String chatId) async {
    final session = _sessions[chatId];
    if (session != null && session.isRunning) await session.stop();
  }

  /// Открытый экран получает `AgentChatDeleted` через свою сессию. В общий
  /// поток событий уведомление не добавляется: сервер публикует его сам, а
  /// иначе один и тот же клиент получил бы событие дважды.
  @override
  void notifyChatDeleted(String chatId) {
    _sessions[chatId]?.notifyDeleted();
  }

  /// Чаты, в которых сейчас идёт ход.
  Set<String> get runningChatIds => {
    for (final session in _sessions.values)
      if (session.isRunning) session.chatId,
  };

  /// Текущий снимок входящих.
  AttentionSnapshot get attentionSnapshot => attention.snapshot;

  /// Изменения входящих для окон и сервера.
  Stream<AttentionSnapshot> get attentionChanges => attention.changes;

  /// Пользователь разобрал проблемное завершение хода вручную.
  Future<void> dismissAttention(String chatId) => attention.dismiss(chatId);

  /// Пользователь отложил напоминание о чате до [until].
  Future<void> snoozeAttention(String chatId, DateTime until) =>
      attention.snooze(chatId, until);

  /// Пользователь вернул отложенный чат раньше срока.
  Future<void> unsnoozeAttention(String chatId) => attention.unsnooze(chatId);

  /// Сроки напоминаний, которые только что наступили.
  Stream<String> get attentionDue => attention.due;

  /// Отложен ли чат прямо сейчас. Уведомления молчат, пока действует срок.
  bool isAttentionSnoozed(String chatId) => attention.isSnoozed(chatId);

  /// Дайджест «пока вас не было» по общей базе агента.
  Future<AttentionDigest> attentionDigest() => attention.digest();

  /// Возвращает сессию чата, создавая её при необходимости. Повторное открытие
  /// того же чата получает прежний экземпляр, пока его не вытеснили.
  @override
  ChatSession session(String chatId) {
    final existing = _sessions[chatId];
    if (existing != null) {
      _touch(chatId);
      return existing;
    }
    final created = ChatSession(chatId, this, _onSessionEvent);
    _sessions[chatId] = created;
    _touch(chatId);
    unawaited(pruneSessions(protectChatId: chatId));
    return created;
  }

  /// Число живых сессий. Нужен для диагностики и проверки вытеснения.
  int get cachedSessionCount => _sessions.length;

  /// Вытесняет простаивающие сессии.
  ///
  /// [idleAfter] — возраст простоя, после которого сессию можно закрыть;
  /// [keep] — сколько последних сессий оставить, даже если они старше.
  /// Сессия с ходом, очередью, карточками, фоновым процессом, субагентом или
  /// подписчиком не вытесняется: новый экземпляр потерял бы её состояние.
  Future<int> pruneSessions({
    Duration idleAfter = sessionIdleAfter,
    int keep = maxCachedSessions,
    String? protectChatId,
  }) async {
    final now = DateTime.now();
    final candidates =
        [
          for (final entry in _sessions.entries)
            if (entry.value.canEvict) entry,
        ]..sort(
          (a, b) =>
              (_sessionTouched[a.key] ?? DateTime.fromMillisecondsSinceEpoch(0))
                  .compareTo(
                    _sessionTouched[b.key] ??
                        DateTime.fromMillisecondsSinceEpoch(0),
                  ),
        );
    var removed = 0;
    for (final entry in candidates) {
      if (entry.key == protectChatId) continue;
      final overLimit = _sessions.length > keep;
      final idle =
          now.difference(
            _sessionTouched[entry.key] ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ) >=
          idleAfter;
      if (!overLimit && !idle) continue;
      if (_sessions.remove(entry.key) == null) continue;
      _sessionTouched.remove(entry.key);
      removed++;
      await entry.value.dispose();
    }
    return removed;
  }

  void _touch(String chatId) => _sessionTouched[chatId] = DateTime.now();

  /// Единый поток событий и обновление LRU. Подписка на [ChatSession.events]
  /// здесь не создаётся: она мешала бы отличать открытый чат от забытого.
  void _onSessionEvent(AgentEvent event) {
    _touch(event.chatId);
    _allEvents.add(event);
  }

  Future<AppLimits> limits() => settings.limits();

  static const _uuid = Uuid();

  /// Сколько несработавших задач попадёт в форк до [untilMessageId].
  ///
  /// Правило то же, что у [forkChat]: задачи берутся по шагам сообщений выше
  /// линии, а строки без шага (записи, созданные до появления шагов в журнале)
  /// относятся к чату по времени создания. Спрашивать пользователя о переносе
  /// имеет смысл только про те задачи, которые действительно перенесутся.
  Future<int> pendingScheduledTasks(
    String chatId, {
    String? untilMessageId,
  }) async {
    final messages = await chats.messages(chatId);
    int? cutSeq;
    DateTime? cutAt;
    for (final message in messages) {
      if (message.id != untilMessageId) continue;
      cutSeq = message.seq;
      cutAt = message.createdAt;
    }
    // Такой линии в чате нет: форк её не примет, переносить нечего.
    if (untilMessageId != null && cutSeq == null) return 0;
    final copiedMessageIds = {
      for (final message in messages)
        if (cutSeq == null || message.seq <= cutSeq) message.id,
    };
    final tasks = await scheduledTasks.forChat(chatId);
    if (tasks.isEmpty) return 0;
    final aboveLine = _taskIdsAboveLine(
      runs: await chats.toolRunsForChat(chatId),
      tasks: tasks,
      copiedMessageIds: copiedMessageIds,
      cutAt: cutAt,
    );
    return tasks
        .where(
          (task) =>
              task.status == ScheduledTaskStatus.pending &&
              aboveLine.contains(task.id),
        )
        .length;
  }

  /// id задач выше линии форка.
  ///
  /// Задача со шагом попадает сюда, если скопировано сообщение её шага. Строка
  /// без шага (созданная до появления шагов в журнале) — если время создания не
  /// позже линии. Одна функция для счётчика и для копии: иначе вопрос и перенос
  /// однажды разойдутся.
  static Set<String> _taskIdsAboveLine({
    required List<ToolRun> runs,
    required List<ScheduledTask> tasks,
    required Set<String> copiedMessageIds,
    required DateTime? cutAt,
  }) {
    final linked = <String>{};
    final aboveLine = <String>{};
    for (final run in runs) {
      final taskId = ScheduledTaskRepository.taskIdOfRun(run);
      if (taskId == null) continue;
      linked.add(taskId);
      if (copiedMessageIds.contains(run.messageId)) aboveLine.add(taskId);
    }
    for (final task in tasks) {
      if (linked.contains(task.id)) continue;
      if (cutAt != null && task.createdAt.isAfter(cutAt)) continue;
      aboveLine.add(task.id);
    }
    return aboveLine;
  }

  /// Форк чата до завершённого ответа [untilMessageId].
  ///
  /// Без [untilMessageId] копируется вся история. С ним — только сообщения до
  /// указанного ответа включительно; состояние берётся из ревизии последнего
  /// пользовательского сообщения этого отрезка. Файлы на Host не копируются
  /// и не откатываются: оба чата смотрят на текущую рабочую папку.
  ///
  /// [copyPendingTasks] переносит в копию и ещё не сработавшие задачи. Это
  /// выбор пользователя: перенос спасает напоминание, если исходный чат потом
  /// удалят, но то же напоминание может сработать дважды. Выполненные задачи
  /// копируются всегда — они часть истории и ничего не запустят.
  Future<Chat> forkChat(
    String chatId, {
    String? title,
    String? untilMessageId,
    bool copyPendingTasks = false,
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
    // Время линии форка: по нему определяется положение задач, у которых нет
    // шага (записи, созданные до появления шагов в журнале).
    DateTime? cutAt;
    for (final message in messages) {
      if (message.id == untilMessageId) cutAt = message.createdAt;
    }
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
      reasoning: source.reasoning,
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
    // Копия открыта пользователю сразу: её история не должна выглядеть
    // непрочитанной. Курсор ставится после вставки, когда известен последний seq.
    if (messages.isNotEmpty) {
      await chats.markRead(id, seq: messages.last.seq);
    }
    // Отложенная задача принадлежит своему шагу `schedule_task`: удалённый шаг
    // уносит и её. Поэтому судьба задачи решается там же, где судьба шага:
    // сообщение ниже линии форка не копируется — задача остаётся в исходном
    // чате, а ожидающая задача, которую решили не переносить, отбрасывается
    // вместе со своим шагом. У задач без шага (созданных до появления шагов в
    // журнале) положение определяется временем создания.
    final allTasks = await scheduledTasks.forChat(chatId);
    final tasksById = {for (final task in allTasks) task.id: task};
    final aboveLine = _taskIdsAboveLine(
      runs: runs,
      tasks: allTasks,
      copiedMessageIds: messageIds.keys.toSet(),
      cutAt: cutAt,
    );
    final referencedTaskIds = <String>{};
    final copiedTaskIds = <String>{};
    for (final run in runs) {
      // Ожидающие и активные запуски в новый чат не переносятся: ответ на
      // карточку принадлежит исходному ходу.
      if (run.isActive) continue;
      final taskId = ScheduledTaskRepository.taskIdOfRun(run);
      if (taskId != null) referencedTaskIds.add(taskId);
      final messageId = messageIds[run.messageId];
      if (messageId == null) continue;
      // Шаг копии должен ссылаться на задачу копии: старый id остался в
      // исходном чате, и удаление шага иначе не нашло бы свою задачу.
      var outputText = run.outputText;
      var resultPreview = run.resultPreview;
      if (taskId != null) {
        final task = tasksById[taskId];
        // Ниже линии форка задача не переносится, значит не нужен и шаг.
        if (task != null && !aboveLine.contains(task.id)) continue;
        if (task != null && !_carryTask(task, copyPendingTasks)) continue;
        if (task != null && copiedTaskIds.add(task.id)) {
          final carried = await scheduledTasks.copyTo(id, task);
          outputText = _retargetTaskId(outputText, task.id, carried.id);
          resultPreview = _retargetTaskId(resultPreview, task.id, carried.id);
        }
      }
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
          resultError: run.resultError,
          exitCode: run.exitCode,
          timedOut: run.timedOut,
          outputText: outputText,
          outputTruncated: run.outputTruncated,
          resultPreview: resultPreview,
          toolCallId: run.toolCallId,
        ),
      );
    }
    // Задачи без шага: их положение определяется временем создания, общая
    // линия уже посчитана в [aboveLine].
    for (final task in allTasks) {
      if (referencedTaskIds.contains(task.id)) continue;
      if (!aboveLine.contains(task.id)) continue;
      if (!_carryTask(task, copyPendingTasks)) continue;
      if (copiedTaskIds.add(task.id)) await scheduledTasks.copyTo(id, task);
    }
    // Читаем копию из БД: у неё уже стоит курсор прочтения, а копия в памяти
    // создавалась до вставки сообщений и знает только пустые значения.
    return await chats.chat(id) ?? copy;
  }

  /// Можно ли переносить задачу. Выполненные задачи копируются всегда:
  /// они часть истории и ничего не запустят.
  static bool _carryTask(ScheduledTask task, bool copyPendingTasks) =>
      task.status != ScheduledTaskStatus.pending || copyPendingTasks;

  /// Текст шага с id задачи копии вместо исходного.
  static String? _retargetTaskId(String? text, String from, String to) =>
      text?.replaceFirst(from, to);

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
