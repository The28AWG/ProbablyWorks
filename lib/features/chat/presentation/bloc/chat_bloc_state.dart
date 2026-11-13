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
    this.hosts = const [],
    this.catalog = const ModelCatalogState(),
    this.pinnedModels = const [],
    this.stepsDisplay = StepsDisplay.defaults,
    this.defaultModelId,
    this.limits = AppLimits.defaults,
    this.streamText = '',
    this.streamReasoning = '',
    this.live = const {},
    this.isRunning = false,
    this.stepLimitReached = false,
    this.failure,
    this.failureModelMissing = false,
    this.promptTokens,
    this.contextLimit,
    this.contextBreakdown,
    this.dailyCostUsd = 0,
    this.dailyBudgetUsd,
    this.compactionInfo,
    this.trustNeeded = false,
    this.loading = false,
    this.attachments = const [],
    this.draft = '',
    this.draftId = 0,
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
  final List<Host> hosts;

  /// Каталог моделей: список, статус загрузки и сохранённые детали выбранных моделей.
  final ModelCatalogState catalog;

  /// Закреплённые id моделей из Settings (показываются первыми в picker).
  final List<String> pinnedModels;

  /// Поведение журнала шагов из Settings: группировка, видимость мыслей и вызовов.
  final StepsDisplay stepsDisplay;

  /// Модель по умолчанию из Settings. Новый чат её не копирует: агент берёт её, пока у чата нет своей.
  final String? defaultModelId;
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

  /// Модели пока нет, но чат ещё грузится: модель по умолчанию из Settings не прочитана, и отсутствие
  /// выбора пока не доказано. Предупреждать об этом рано; после загрузки null означает реальную ошибку.
  bool get modelPending => loading && effectiveModelId == null;

  /// Статус модели чата по кешу каталога. Недоступная модель не блокирует отправку: `!` предупреждает.
  ModelStatus get modelStatus => catalog.statusOf(effectiveModelId);

  bool get modelUnavailable => modelStatus == ModelStatus.unavailable;

  /// Текст шага, который ещё не записан в БД (живой стрим).
  final String streamText;

  /// Рассуждения модели, которые ещё не записаны в БД (живой стрим).
  final String streamReasoning;

  /// Живой вывод команд по runId (только пока команда выполняется).
  final Map<String, String> live;
  final bool isRunning;
  final bool stepLimitReached;
  final String? failure;

  /// Последняя ошибка — модель не найдена на сервере (см. [failureIsModelMissing]).
  final bool failureModelMissing;

  /// Ошибка есть и она из-за модели: док показывает предупреждение о модели вместо сырого текста.
  bool get failureIsModelMissing => failure != null && failureModelMissing;
  final int? promptTokens;
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

  /// Текст, который нужно положить в поле ввода: смена чата, правка элемента очереди, подсказка.
  /// [draftId] меняется на каждый такой запрос, поэтому поле переписывается только по нему.
  final String draft;
  final int draftId;

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
    List<Host>? hosts,
    ModelCatalogState? catalog,
    List<String>? pinnedModels,
    StepsDisplay? stepsDisplay,
    String? defaultModelId,
    AppLimits? limits,
    String? streamText,
    String? streamReasoning,
    Map<String, String>? live,
    bool? isRunning,
    bool? stepLimitReached,
    String? failure,
    bool? failureModelMissing,
    bool clearFailure = false,
    int? promptTokens,
    int? contextLimit,
    ContextBreakdown? contextBreakdown,
    double? dailyCostUsd,
    double? dailyBudgetUsd,
    bool clearDailyBudget = false,
    ChatCompactionInfo? compactionInfo,
    bool clearCompactionInfo = false,
    bool? trustNeeded,
    bool? loading,
    List<AttachmentRef>? attachments,
    String? draft,
    int? draftId,
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
    hosts: hosts ?? this.hosts,
    catalog: catalog ?? this.catalog,
    pinnedModels: pinnedModels ?? this.pinnedModels,
    stepsDisplay: stepsDisplay ?? this.stepsDisplay,
    defaultModelId: defaultModelId ?? this.defaultModelId,
    limits: limits ?? this.limits,
    streamText: streamText ?? this.streamText,
    streamReasoning: streamReasoning ?? this.streamReasoning,
    live: live ?? this.live,
    isRunning: isRunning ?? this.isRunning,
    stepLimitReached: stepLimitReached ?? this.stepLimitReached,
    failure: clearFailure ? null : (failure ?? this.failure),
    failureModelMissing: failureModelMissing ?? this.failureModelMissing,
    promptTokens: promptTokens ?? this.promptTokens,
    contextLimit: contextLimit ?? this.contextLimit,
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
    draft: draft ?? this.draft,
    draftId: draftId ?? this.draftId,
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
    hosts,
    catalog,
    pinnedModels,
    stepsDisplay,
    defaultModelId,
    limits,
    streamText,
    streamReasoning,
    live,
    isRunning,
    stepLimitReached,
    failure,
    failureModelMissing,
    promptTokens,
    contextLimit,
    contextBreakdown,
    dailyCostUsd,
    dailyBudgetUsd,
    compactionInfo,
    trustNeeded,
    loading,
    attachments,
    draft,
    draftId,
    unsaved,
  ];
}
