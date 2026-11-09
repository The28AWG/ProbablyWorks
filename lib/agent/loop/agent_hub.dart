import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/context/context_builder.dart';
import 'package:probably_works/agent/context/context_compactor.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/exec/active_exec_registry.dart';
import 'package:probably_works/agent/exec/exec_log_store.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/agent/loop/agent_event.dart';
import 'package:probably_works/agent/loop/chat_session.dart';
import 'package:probably_works/agent/project/project_lifecycle.dart';
import 'package:probably_works/agent/state/session_state_service.dart';
import 'package:probably_works/agent/tools/tool_executor.dart';
import 'package:probably_works/agent/workspace/workspace_context_loader.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/policy_profile_repository.dart';
import 'package:probably_works/core/data/project_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/notify/app_notifier.dart';
import 'package:probably_works/host/host_runtime_factory.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';
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
    this.workspace,
    this.state,
    this.broker,
    this.registry,
    this.logs,
    this.notifier,
    this.projects,
    this.projectStore,
    this.policyProfiles,
  );

  final ChatRepository chats;
  final SettingsRepository settings;
  final HostRepository hosts;
  final HostRuntimeFactory runtimes;
  final LlmProvider llm;
  final ModelCatalogService models;
  final ContextBuilder builder;
  final ContextCompactor compactor;
  final ToolExecutor tools;
  final WorkspaceContextLoader workspace;
  final SessionStateService state;
  final InteractionBroker broker;
  final ActiveExecRegistry registry;
  final ExecLogStore logs;
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
