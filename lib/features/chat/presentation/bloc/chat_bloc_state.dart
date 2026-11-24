part of 'chat_bloc.dart';

// ---- state ------------------------------------------------------------------

class ChatState extends Equatable {
  const ChatState({
    this.chatId,
    this.chat,
    this.project,
    this.messages = const [],
    this.runs = const [],
    this.queue = const [],
    this.approvals = const [],
    this.questions = const [],
    this.editFileChanges = const [],
    this.draftConflict,
    this.clientSessions = const [],
    this.otherSessions = const [],
    this.hosts = const [],
    this.catalog = const ModelCatalogState(),
    this.pinnedModels = const [],
    this.stepsDisplay = StepsDisplay.defaults,
    this.defaultModelId,
    this.defaultReasoning = ReasoningPreference.auto,
    this.limits = AppLimits.defaults,
    this.streamText = '',
    this.streamReasoning = '',
    this.live = const {},
    this.isRunning = false,
    this.stepLimitReached = false,
    this.budgetReached = false,
    this.stalledReached = false,
    this.failure,
    this.failureModelMissing = false,
    this.promptTokens,
    this.promptTokensEstimated = false,
    this.contextWindowKnown = true,
    this.contextLimit,
    this.contextBreakdown,
    this.dailyCostUsd = 0,
    this.dailyBudgetUsd,
    this.compactionInfo,
    this.trustNeeded = false,
    this.loading = false,
    this.attachments = const [],
    this.mentions = const [],
    this.draft = '',
    this.draftId = 0,
    this.messageEditsId = 0,
    this.unsaved = false,
  });

  final String? chatId;
  final Chat? chat;

  /// Проект открытого чата. Null у нового чата до первой отправки.
  final Project? project;

  /// Чат ещё не записан в БД (новый чат до первой отправки). Его настройки живут в памяти.
  final bool unsaved;
  final List<ChatMessage> messages;
  final List<ToolRun> runs;

  final List<String> queue;
  final List<ApprovalRequest> approvals;
  final List<UserQuestion> questions;
  final List<EditFileChangesRequest> editFileChanges;

  /// Конфликт черновика или правок, который ждёт решения пользователя.
  final DraftConflict? draftConflict;

  /// Все клиентские сессии, включая текущую.
  ///
  /// Нужны диалогу присутствия: в шапке он должен показывать тот же полный
  /// список, что и в боковой панели, иначе один экран выглядит как «пропавший».
  final List<ClientSessionView> clientSessions;

  /// Другие клиенты, у которых открыт этот же чат.
  final List<ClientSessionView> otherSessions;
  final List<Host> hosts;

  /// Каталог моделей: список, статус загрузки и сохранённые детали выбранных моделей.
  final ModelCatalogState catalog;

  /// Закреплённые id моделей из Settings (показываются первыми в picker).
  final List<String> pinnedModels;

  /// Поведение журнала шагов из Settings: группировка, видимость мыслей и вызовов.
  final StepsDisplay stepsDisplay;

  /// Модель по умолчанию из Settings. Новый чат её не копирует: агент берёт её, пока у чата нет своей.
  final String? defaultModelId;

  /// Уровень рассуждений по умолчанию. Чат с `inherit` следует ему.
  final ReasoningPreference defaultReasoning;
  final AppLimits limits;

  /// Модель, которую агент реально использует в этом чате: своя или по умолчанию. Null, если ничего не выбрано.
  String? get effectiveModelId {
    final own = chat?.model;
    if (own != null && own.isNotEmpty) return own;
    if (defaultModelId != null && defaultModelId!.isNotEmpty) {
      return defaultModelId;
    }
    return null;
  }

  /// Выбор уровня чата: `inherit` означает «как в настройках».
  ReasoningPreference get chatReasoning =>
      chat?.reasoning ?? ReasoningPreference.inherit;

  /// Действующий выбор с учётом настроек.
  ReasoningPreference get effectiveReasoning =>
      chatReasoning == ReasoningPreference.inherit
      ? defaultReasoning
      : chatReasoning;

  /// Возможности рассуждений выбранной модели. Null — каталог модель не описал;
  /// для таких моделей UI показывает общий набор уровней.
  LlmReasoningCapability? get reasoningCapability {
    final id = effectiveModelId;
    if (id == null) return null;
    return catalog.modelOf(id)?.reasoning ?? catalog.saved[id]?.reasoning;
  }

  /// Уровень, который реально уйдёт в запрос. Null — поле не отправляется.
  ReasoningEffort? get effectiveReasoningEffort => resolveReasoning(
    capability: reasoningCapability,
    preference: effectiveReasoning,
  );

  /// Модели пока нет, но чат ещё грузится: модель по умолчанию из Settings не прочитана, и отсутствие
  /// выбора пока не доказано. Предупреждать об этом рано; после загрузки null означает реальную ошибку.
  bool get modelPending => loading && effectiveModelId == null;

  /// Статус модели чата по кешу каталога. Недоступная модель не блокирует отправку: `!` предупреждает.
  ModelStatus get modelStatus => catalog.statusOf(effectiveModelId);

  bool get modelUnavailable => modelStatus == ModelStatus.unavailable;

  /// Модель в каталоге есть, но её провайдер не отвечает.
  bool get modelProviderUnavailable =>
      modelStatus == ModelStatus.providerUnavailable;

  /// Провайдер модели выключен в настройках.
  bool get modelProviderDisabled => modelStatus == ModelStatus.providerDisabled;

  /// Любая проблема с моделью или её провайдером: чип показывает `!`.
  bool get modelHasProblem =>
      modelUnavailable || modelProviderUnavailable || modelProviderDisabled;

  /// Текст шага, который ещё не записан в БД (живой стрим).
  final String streamText;

  /// Рассуждения модели, которые ещё не записаны в БД (живой стрим).
  final String streamReasoning;

  /// Живой вывод команд по runId (только пока команда выполняется).
  final Map<String, String> live;
  final bool isRunning;
  final bool stepLimitReached;

  /// Ход остановлен из-за бюджета (токены, стоимость или время).
  final bool budgetReached;

  /// Ход остановлен: агент повторял действия без нового результата.
  final bool stalledReached;
  final String? failure;

  /// Последняя ошибка — модель не найдена на сервере (см. [failureIsModelMissing]).
  final bool failureModelMissing;

  /// Ошибка есть и она из-за модели: док показывает предупреждение о модели вместо сырого текста.
  bool get failureIsModelMissing => failure != null && failureModelMissing;

  /// Последний размер контекста: точное значение от провайдера или оценка.
  final int? promptTokens;

  /// [promptTokens] — оценка, а не точное значение провайдера. Показывается
  /// с «≈» в диалоге; после первого точного usage оценка не используется.
  final bool promptTokensEstimated;

  /// Размер окна модели известен. false — предел подставлен консервативно,
  /// и диалог контекста предупреждает, что он может быть неточным.
  final bool contextWindowKnown;
  final int? contextLimit;
  final ContextBreakdown? contextBreakdown;
  final double dailyCostUsd;
  final double? dailyBudgetUsd;

  /// Последнее сжатие истории: когда, почему и до какой границы.
  final ChatCompactionInfo? compactionInfo;
  final bool trustNeeded;

  /// Стоимость последнего запроса по ценам каталога. Null — цены модели
  /// ещё неизвестны или модель не выбрана.
  double? get lastRequestCostUsd {
    final modelId = effectiveModelId;
    final info = modelId == null ? null : catalog.modelOf(modelId);
    final promptPrice = double.tryParse(info?.promptPrice ?? '');
    final completionPrice = double.tryParse(info?.completionPrice ?? '');
    if (promptPrice == null || completionPrice == null) return null;
    final prompt = chat?.lastPromptTokens;
    final completion = chat?.lastCompletionTokens;
    if (prompt == null && completion == null) return null;
    return promptPrice * (prompt ?? 0) + completionPrice * (completion ?? 0);
  }

  final bool loading;

  /// Вложения черновика текущего чата (до отправки).
  final List<AttachmentRef> attachments;

  /// Упоминания файлов и каталогов в черновике. Диапазоны указывают на [draft].
  final List<MentionRef> mentions;

  /// Текст, который нужно положить в поле ввода: смена чата, правка элемента очереди, подсказка.
  /// [draftId] меняется на каждый такой запрос, поэтому поле переписывается только по нему.
  final String draft;
  final int draftId;

  /// Счётчик обновлений неотправленных правок сообщений. Меняется без
  /// [draftId], чтобы удалённая правка перерисовала ленту, не сбрасывая
  /// курсор в поле ввода.
  ///
  /// Лента читает правки из [ChatDraftStore] напрямую, а не из этого поля:
  /// счётчик нужен только чтобы `ChatState` перестал быть равным самому себе
  /// и `BlocBuilder` перестроил экран. Если когда-нибудь появится `buildWhen`,
  /// его нужно научить учитывать это поле, иначе чужие правки перестанут
  /// появляться.
  final int messageEditsId;

  ChatState copyWith({
    String? chatId,
    Chat? chat,
    Project? project,
    bool clearProject = false,
    List<ChatMessage>? messages,
    List<ToolRun>? runs,
    List<String>? queue,
    List<ApprovalRequest>? approvals,
    List<UserQuestion>? questions,
    List<EditFileChangesRequest>? editFileChanges,
    DraftConflict? draftConflict,
    bool clearDraftConflict = false,
    List<ClientSessionView>? clientSessions,
    List<ClientSessionView>? otherSessions,
    List<Host>? hosts,
    ModelCatalogState? catalog,
    List<String>? pinnedModels,
    StepsDisplay? stepsDisplay,
    String? defaultModelId,
    ReasoningPreference? defaultReasoning,
    AppLimits? limits,
    String? streamText,
    String? streamReasoning,
    Map<String, String>? live,
    bool? isRunning,
    bool? stepLimitReached,
    bool? budgetReached,
    bool? stalledReached,
    String? failure,
    bool? failureModelMissing,
    bool clearFailure = false,
    int? promptTokens,
    bool? promptTokensEstimated,
    bool? contextWindowKnown,
    int? contextLimit,
    bool clearContextLimit = false,
    ContextBreakdown? contextBreakdown,
    double? dailyCostUsd,
    double? dailyBudgetUsd,
    bool clearDailyBudget = false,
    ChatCompactionInfo? compactionInfo,
    bool clearCompactionInfo = false,
    bool? trustNeeded,
    bool? loading,
    List<AttachmentRef>? attachments,
    List<MentionRef>? mentions,
    String? draft,
    int? draftId,
    int? messageEditsId,
    bool? unsaved,
  }) => ChatState(
    chatId: chatId ?? this.chatId,
    chat: chat ?? this.chat,
    project: clearProject ? null : (project ?? this.project),
    messages: messages ?? this.messages,
    runs: runs ?? this.runs,
    queue: queue ?? this.queue,
    approvals: approvals ?? this.approvals,
    questions: questions ?? this.questions,
    editFileChanges: editFileChanges ?? this.editFileChanges,
    draftConflict: clearDraftConflict
        ? null
        : (draftConflict ?? this.draftConflict),
    clientSessions: clientSessions ?? this.clientSessions,
    otherSessions: otherSessions ?? this.otherSessions,
    hosts: hosts ?? this.hosts,
    catalog: catalog ?? this.catalog,
    pinnedModels: pinnedModels ?? this.pinnedModels,
    stepsDisplay: stepsDisplay ?? this.stepsDisplay,
    defaultModelId: defaultModelId ?? this.defaultModelId,
    defaultReasoning: defaultReasoning ?? this.defaultReasoning,
    limits: limits ?? this.limits,
    streamText: streamText ?? this.streamText,
    streamReasoning: streamReasoning ?? this.streamReasoning,
    live: live ?? this.live,
    isRunning: isRunning ?? this.isRunning,
    stepLimitReached: stepLimitReached ?? this.stepLimitReached,
    budgetReached: budgetReached ?? this.budgetReached,
    stalledReached: stalledReached ?? this.stalledReached,
    failure: clearFailure ? null : (failure ?? this.failure),
    failureModelMissing: failureModelMissing ?? this.failureModelMissing,
    promptTokens: promptTokens ?? this.promptTokens,
    promptTokensEstimated: promptTokensEstimated ?? this.promptTokensEstimated,
    contextWindowKnown: contextWindowKnown ?? this.contextWindowKnown,
    contextLimit: clearContextLimit
        ? null
        : (contextLimit ?? this.contextLimit),
    contextBreakdown: contextBreakdown ?? this.contextBreakdown,
    dailyCostUsd: dailyCostUsd ?? this.dailyCostUsd,
    dailyBudgetUsd: clearDailyBudget
        ? null
        : (dailyBudgetUsd ?? this.dailyBudgetUsd),
    compactionInfo: clearCompactionInfo
        ? null
        : (compactionInfo ?? this.compactionInfo),
    trustNeeded: trustNeeded ?? this.trustNeeded,
    loading: loading ?? this.loading,
    attachments: attachments ?? this.attachments,
    mentions: mentions ?? this.mentions,
    draft: draft ?? this.draft,
    draftId: draftId ?? this.draftId,
    messageEditsId: messageEditsId ?? this.messageEditsId,
    unsaved: unsaved ?? this.unsaved,
  );

  @override
  List<Object?> get props => [
    chatId,
    chat,
    project,
    messages,
    runs,
    queue,
    approvals,
    questions,
    editFileChanges,
    draftConflict,
    clientSessions,
    otherSessions,
    hosts,
    catalog,
    pinnedModels,
    stepsDisplay,
    defaultModelId,
    defaultReasoning,
    limits,
    streamText,
    streamReasoning,
    live,
    isRunning,
    stepLimitReached,
    budgetReached,
    stalledReached,
    failure,
    failureModelMissing,
    promptTokens,
    promptTokensEstimated,
    contextWindowKnown,
    contextLimit,
    contextBreakdown,
    dailyCostUsd,
    dailyBudgetUsd,
    compactionInfo,
    trustNeeded,
    loading,
    attachments,
    mentions,
    draft,
    draftId,
    messageEditsId,
    unsaved,
  ];
}
