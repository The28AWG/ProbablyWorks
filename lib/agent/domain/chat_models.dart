import 'dart:convert';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:probably_works/core/util/redactor.dart';

enum PolicyMode { ask, yolo }

enum ChatTitleSource { none, generated, user }

enum MessageRole { user, assistant, tool, event }

/// attach — текстовый файл, его текст входит в сообщение; file — бинарный файл (PDF, изображение),
/// его байты уходят модели отдельной частью, только в первом запросе хода.
enum AttachmentMode { attach, file }

/// Вызов инструмента, который модель запросила в assistant-сообщении.
class ToolCallRef {
  const ToolCallRef({
    required this.id,
    required this.name,
    required this.arguments,
  });

  factory ToolCallRef.fromJson(Map<String, dynamic> json) => ToolCallRef(
    id: json['id'] as String,
    name: json['name'] as String,
    arguments: json['arguments'] as String,
  );

  final String id;
  final String name;
  final String arguments;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
  };
}

/// Вложение пользователя. Путь на диске не хранится и не передаётся: модели уходит только содержимое.
/// Байты ([bytes]) живут в памяти до первого запроса хода и в БД не пишутся.
class AttachmentRef {
  const AttachmentRef({
    required this.name,
    required this.mode,
    this.content,
    this.mimeType,
    this.sizeBytes = 0,
    this.bytes,
  });

  /// Старые записи с режимом `mention` (путь без содержимого) читаются как file без байтов.
  factory AttachmentRef.fromJson(Map<String, dynamic> json) => AttachmentRef(
    name: json['name'] as String,
    mode: json['mode'] == AttachmentMode.attach.name
        ? AttachmentMode.attach
        : AttachmentMode.file,
    content: json['content'] as String?,
    mimeType: json['mimeType'] as String?,
    sizeBytes: json['sizeBytes'] as int? ?? 0,
  );

  final String name;
  final AttachmentMode mode;

  /// Текст файла (только для [AttachmentMode.attach]).
  final String? content;

  /// MIME-тип бинарного файла (только для [AttachmentMode.file]).
  final String? mimeType;
  final int sizeBytes;

  /// Содержимое бинарного файла в памяти. Не сохраняется в БД и черновиках.
  final Uint8List? bytes;

  /// Есть ли содержимое, которое можно отправить модели прямо сейчас.
  bool get hasContent => switch (mode) {
    AttachmentMode.attach => content != null,
    AttachmentMode.file => bytes != null,
  };

  Map<String, dynamic> toJson() => {
    'name': name,
    'mode': mode.name,
    'content': content,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
  };

  /// Копия с замаскированными секретами в тексте вложения (перед записью в БД и отправкой модели).
  /// Байты не маскируются и остаются в памяти.
  AttachmentRef redacted() => AttachmentRef(
    name: name,
    mode: mode,
    content: content == null ? null : Redactor.redact(content!),
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    bytes: bytes,
  );
}

/// Черновик поля ввода чата: текст и вложения, которые пользователь ещё не отправил.
class ChatDraft extends Equatable {
  const ChatDraft({this.text = '', this.attachments = const []});

  static const empty = ChatDraft();

  final String text;
  final List<AttachmentRef> attachments;

  bool get isEmpty => text.isEmpty && attachments.isEmpty;

  @override
  List<Object?> get props => [text, attachments];
}

class Chat {
  const Chat({
    required this.id,
    required this.hostId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.projectId,
    this.titleSource = ChatTitleSource.none,
    this.model,
    this.policyMode = PolicyMode.ask,
    this.workspace,
    this.lastPromptTokens,
    this.lastCompletionTokens,
    this.contextLength,
    this.compactionSummary,
    this.compactedUntilSeq = 0,
    this.currentRevisionId,
    this.draft = ChatDraft.empty,
  });

  final String id;
  final String hostId;

  /// Проект чата. Null, пока папка не выбрана и хост не задаёт свою:
  /// неявный домашний каталог общим проектом не становится.
  final String? projectId;
  final String title;
  final ChatTitleSource titleSource;
  final String? model;
  final PolicyMode policyMode;
  final String? workspace;
  final int? lastPromptTokens;
  final int? lastCompletionTokens;
  final int? contextLength;
  final String? compactionSummary;
  final int compactedUntilSeq;
  final String? currentRevisionId;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Черновик, сохранённый вместе с чатом. Записывается отдельно от остальных полей (см. ChatRepository.saveDraft).
  final ChatDraft draft;

  Chat copyWith({
    String? id,
    String? hostId,
    String? projectId,
    bool clearProjectId = false,
    String? title,
    ChatTitleSource? titleSource,
    String? model,
    PolicyMode? policyMode,
    String? workspace,
    bool clearWorkspace = false,
    int? lastPromptTokens,
    int? lastCompletionTokens,
    int? contextLength,
    String? compactionSummary,
    bool clearCompactionSummary = false,
    int? compactedUntilSeq,
    String? currentRevisionId,
    DateTime? createdAt,
    DateTime? updatedAt,
    ChatDraft? draft,
  }) => Chat(
    id: id ?? this.id,
    hostId: hostId ?? this.hostId,
    projectId: clearProjectId ? null : (projectId ?? this.projectId),
    title: title ?? this.title,
    titleSource: titleSource ?? this.titleSource,
    model: model ?? this.model,
    policyMode: policyMode ?? this.policyMode,
    workspace: clearWorkspace ? null : (workspace ?? this.workspace),
    lastPromptTokens: lastPromptTokens ?? this.lastPromptTokens,
    lastCompletionTokens: lastCompletionTokens ?? this.lastCompletionTokens,
    contextLength: contextLength ?? this.contextLength,
    compactionSummary: clearCompactionSummary
        ? null
        : (compactionSummary ?? this.compactionSummary),
    compactedUntilSeq: compactedUntilSeq ?? this.compactedUntilSeq,
    currentRevisionId: currentRevisionId ?? this.currentRevisionId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? DateTime.now(),
    draft: draft ?? this.draft,
  );
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.chatId,
    required this.seq,
    required this.role,
    required this.createdAt,
    this.text = '',
    this.reasoning = '',
    this.toolCalls = const [],
    this.toolCallId,
    this.attachments = const [],
    this.openedRevisionId,
    this.sealedBeforeRevisionId,
  });

  factory ChatMessage.decode({
    required String id,
    required String chatId,
    required int seq,
    required String role,
    required String payload,
    required DateTime createdAt,
    String? openedRevisionId,
    String? sealedBeforeRevisionId,
  }) {
    final map = jsonDecode(payload) as Map<String, dynamic>;
    return ChatMessage(
      id: id,
      chatId: chatId,
      seq: seq,
      role: MessageRole.values.byName(role),
      createdAt: createdAt,
      text: map['text'] as String? ?? '',
      reasoning: map['reasoning'] as String? ?? '',
      toolCalls: [
        for (final c in (map['toolCalls'] as List? ?? const []))
          ToolCallRef.fromJson(c as Map<String, dynamic>),
      ],
      toolCallId: map['toolCallId'] as String?,
      attachments: [
        for (final a in (map['attachments'] as List? ?? const []))
          AttachmentRef.fromJson(a as Map<String, dynamic>),
      ],
      openedRevisionId: openedRevisionId,
      sealedBeforeRevisionId: sealedBeforeRevisionId,
    );
  }

  final String id;
  final String chatId;
  final int seq;
  final MessageRole role;
  final String text;

  /// Рассуждения модели перед этим шагом. Показываются в журнале шагов, модели не отправляются.
  final String reasoning;
  final List<ToolCallRef> toolCalls;
  final String? toolCallId;
  final List<AttachmentRef> attachments;
  final DateTime createdAt;
  final String? openedRevisionId;
  final String? sealedBeforeRevisionId;

  ChatMessage copyWith({
    String? id,
    String? chatId,
    int? seq,
    MessageRole? role,
    String? text,
    String? reasoning,
    List<ToolCallRef>? toolCalls,
    String? toolCallId,
    List<AttachmentRef>? attachments,
    DateTime? createdAt,
    String? openedRevisionId,
    String? sealedBeforeRevisionId,
  }) => ChatMessage(
    id: id ?? this.id,
    chatId: chatId ?? this.chatId,
    seq: seq ?? this.seq,
    role: role ?? this.role,
    createdAt: createdAt ?? this.createdAt,
    text: text ?? this.text,
    reasoning: reasoning ?? this.reasoning,
    toolCalls: toolCalls ?? this.toolCalls,
    toolCallId: toolCallId ?? this.toolCallId,
    attachments: attachments ?? this.attachments,
    openedRevisionId: openedRevisionId ?? this.openedRevisionId,
    sealedBeforeRevisionId:
        sealedBeforeRevisionId ?? this.sealedBeforeRevisionId,
  );

  /// Полезная нагрузка для колонки `payload` (JSON).
  String encodePayload() => jsonEncode({
    'text': text,
    'reasoning': reasoning,
    'toolCalls': [for (final c in toolCalls) c.toJson()],
    'toolCallId': toolCallId,
    'attachments': [for (final a in attachments) a.toJson()],
  });
}

enum ToolRunStatus {
  running,
  waitingApproval,
  waitingUser,
  done,
  failed,
  timedOut,
  interrupted,
  denied,
  connectionLost,
  spawnFailed,
  backgroundRunning,
}

/// Запись о выполнении инструмента: аудит, карточка в ленте и связь с логом.
class ToolRun {
  const ToolRun({
    required this.id,
    required this.chatId,
    required this.messageId,
    required this.toolName,
    required this.argsJson,
    required this.status,
    required this.startedAt,
    this.command,
    this.background = false,
    this.pid,
    this.exitCode,
    this.timedOut = false,
    this.logPath,
    this.outputText,
    this.outputTruncated = false,
    this.resultPreview,
    this.finishedAt,
    this.toolCallId,
    this.pendingCard,
  });

  final String id;
  final String chatId;
  final String messageId;
  final String toolName;
  final String argsJson;
  final String? command;
  final bool background;
  final int? pid;
  final ToolRunStatus status;
  final int? exitCode;
  final bool timedOut;
  final String? logPath;
  final String? outputText;
  final bool outputTruncated;
  final String? resultPreview;
  final DateTime startedAt;
  final DateTime? finishedAt;

  /// Id вызова в сообщении ассистента. У старых строк пусто: тогда ход сопоставляет вызов по имени и аргументам.
  final String? toolCallId;

  /// JSON карточки подтверждения, пока пользователь не ответил. После ответа очищается.
  final String? pendingCard;

  bool get isActive =>
      status == ToolRunStatus.running ||
      status == ToolRunStatus.backgroundRunning ||
      status == ToolRunStatus.waitingApproval ||
      status == ToolRunStatus.waitingUser;

  ToolRun copyWith({
    String? id,
    String? chatId,
    String? messageId,
    String? toolName,
    String? argsJson,
    String? command,
    bool? background,
    ToolRunStatus? status,
    int? pid,
    int? exitCode,
    bool? timedOut,
    String? logPath,
    bool clearLogPath = false,
    String? outputText,
    bool? outputTruncated,
    String? resultPreview,
    DateTime? startedAt,
    DateTime? finishedAt,
    String? toolCallId,
    String? pendingCard,
    bool clearPendingCard = false,
  }) => ToolRun(
    id: id ?? this.id,
    chatId: chatId ?? this.chatId,
    messageId: messageId ?? this.messageId,
    toolName: toolName ?? this.toolName,
    argsJson: argsJson ?? this.argsJson,
    command: command ?? this.command,
    background: background ?? this.background,
    pid: pid ?? this.pid,
    status: status ?? this.status,
    exitCode: exitCode ?? this.exitCode,
    timedOut: timedOut ?? this.timedOut,
    logPath: clearLogPath ? null : (logPath ?? this.logPath),
    outputText: outputText ?? this.outputText,
    outputTruncated: outputTruncated ?? this.outputTruncated,
    resultPreview: resultPreview ?? this.resultPreview,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    toolCallId: toolCallId ?? this.toolCallId,
    pendingCard: clearPendingCard ? null : (pendingCard ?? this.pendingCard),
  );
}
