import 'dart:convert';

import 'package:probably_works/core/util/redactor.dart';

enum PolicyMode { ask, yolo }

enum ChatTitleSource { none, generated, user }

enum MessageRole { user, assistant, tool, event }

enum AttachmentMode { attach, mention }

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

/// Вложение пользователя: либо содержимое в контекст, либо путь для агента.
class AttachmentRef {
  const AttachmentRef({
    required this.name,
    required this.mode,
    this.content,
    this.path,
    this.sizeBytes = 0,
  });

  factory AttachmentRef.fromJson(Map<String, dynamic> json) => AttachmentRef(
    name: json['name'] as String,
    mode: AttachmentMode.values.byName(json['mode'] as String),
    content: json['content'] as String?,
    path: json['path'] as String?,
    sizeBytes: json['sizeBytes'] as int? ?? 0,
  );

  final String name;
  final AttachmentMode mode;
  final String? content;
  final String? path;
  final int sizeBytes;

  Map<String, dynamic> toJson() => {
    'name': name,
    'mode': mode.name,
    'content': content,
    'path': path,
    'sizeBytes': sizeBytes,
  };

  /// Копия с замаскированными секретами в тексте вложения (перед записью в БД и отправкой модели).
  AttachmentRef redacted() => AttachmentRef(
    name: name,
    mode: mode,
    content: content == null ? null : Redactor.redact(content!),
    path: path,
    sizeBytes: sizeBytes,
  );
}

class Chat {
  const Chat({
    required this.id,
    required this.hostId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
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
  });

  final String id;
  final String hostId;
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

  Chat copyWith({
    String? id,
    String? hostId,
    String? title,
    ChatTitleSource? titleSource,
    String? model,
    PolicyMode? policyMode,
    String? workspace,
    int? lastPromptTokens,
    int? lastCompletionTokens,
    int? contextLength,
    String? compactionSummary,
    bool clearCompactionSummary = false,
    int? compactedUntilSeq,
    String? currentRevisionId,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Chat(
    id: id ?? this.id,
    hostId: hostId ?? this.hostId,
    title: title ?? this.title,
    titleSource: titleSource ?? this.titleSource,
    model: model ?? this.model,
    policyMode: policyMode ?? this.policyMode,
    workspace: workspace ?? this.workspace,
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
  );
}
