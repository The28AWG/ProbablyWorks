import 'dart:convert';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:pw_agent/core/util/redactor.dart';
import 'package:pw_agent/providers/ai/reasoning.dart';

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

/// Что именно упомянуто в тексте сообщения.
enum MentionKind { file, directory }

/// Упоминание файла или каталога workspace.
///
/// В тексте сообщения лежит только последний сегмент пути (`@app.dart`), а
/// полный путь хранится здесь. Диапазон [start]-[end] (UTF-16) связывает
/// метаданные с токеном в тексте. Поэтому переименование или повторный выбор
/// файла не требуют угадывать путь по имени: источник истины — [path].
class MentionRef extends Equatable {
  const MentionRef({
    required this.kind,
    required this.path,
    required this.start,
    required this.end,
  });

  factory MentionRef.fromJson(Map<String, dynamic> json) => MentionRef(
    kind: MentionKind.values.asNameMap()['${json['kind']}'] ?? MentionKind.file,
    path: '${json['path'] ?? ''}',
    start: (json['start'] as num?)?.toInt() ?? -1,
    end: (json['end'] as num?)?.toInt() ?? -1,
  );

  final MentionKind kind;

  /// Путь относительно workspace без хвостового `/`.
  final String path;

  /// Смещение `@` в тексте сообщения.
  final int start;

  /// Смещение сразу после токена.
  final int end;

  MentionRef copyWith({
    MentionKind? kind,
    String? path,
    int? start,
    int? end,
  }) => MentionRef(
    kind: kind ?? this.kind,
    path: path ?? this.path,
    start: start ?? this.start,
    end: end ?? this.end,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'path': path,
    'start': start,
    'end': end,
  };

  @override
  List<Object?> get props => [kind, path, start, end];
}

/// Черновик поля ввода чата: текст, вложения и упоминания, которые пользователь ещё не отправил.
class ChatDraft extends Equatable {
  const ChatDraft({
    this.text = '',
    this.attachments = const [],
    this.mentions = const [],
  });

  static const empty = ChatDraft();

  final String text;
  final List<AttachmentRef> attachments;
  final List<MentionRef> mentions;

  bool get isEmpty => text.isEmpty && attachments.isEmpty && mentions.isEmpty;

  @override
  List<Object?> get props => [text, attachments, mentions];
}

/// Черновики правки уже отправленных сообщений: id сообщения → текст и вложения.
///
/// Пустая строка и `{}` — правок нет. Байты бинарных файлов в JSON не пишутся, как у черновика
/// композера: после перезапуска такой файл нужно прикрепить заново.
String encodeMessageEdits(Map<String, ChatDraft> edits) => jsonEncode({
  for (final entry in edits.entries)
    entry.key: {
      'text': entry.value.text,
      'attachments': [
        for (final attachment in entry.value.attachments)
          attachment.redacted().toJson(),
      ],
      'mentions': [
        for (final mention in entry.value.mentions) mention.toJson(),
      ],
    },
});

/// Читает [encodeMessageEdits]. Повреждённая запись читается как пустая карта, а не как ошибка:
/// чат должен открываться, даже если черновик правки не разобрать.
Map<String, ChatDraft> decodeMessageEdits(String raw) {
  if (raw.isEmpty || raw == '{}') return const {};
  final decoded = jsonDecode(raw);
  if (decoded is! Map) return const {};
  final result = <String, ChatDraft>{};
  for (final entry in decoded.entries) {
    final value = entry.value;
    if (value is! Map) continue;
    final text = value['text'];
    final attachments = <AttachmentRef>[];
    final rawAttachments = value['attachments'];
    if (rawAttachments is List) {
      for (final item in rawAttachments) {
        if (item is Map<String, dynamic>) {
          attachments.add(AttachmentRef.fromJson(item));
        } else if (item is Map) {
          attachments.add(
            AttachmentRef.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final mentions = <MentionRef>[];
    final rawMentions = value['mentions'];
    if (rawMentions is List) {
      for (final item in rawMentions) {
        if (item is Map<String, dynamic>) {
          mentions.add(MentionRef.fromJson(item));
        } else if (item is Map) {
          mentions.add(MentionRef.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    result['${entry.key}'] = ChatDraft(
      text: text is String ? text : '',
      attachments: attachments,
      mentions: mentions,
    );
  }
  return result;
}

/// Роль чата: обычный пользовательский или скрытый чат субагента.
enum ChatKind { main, subagent }

class Chat {
  const Chat({
    required this.id,
    required this.hostId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.kind = ChatKind.main,
    this.parentChatId,
    this.rootChatId,
    this.depth = 0,
    this.projectId,
    this.titleSource = ChatTitleSource.none,
    this.model,
    this.reasoning = ReasoningPreference.inherit,
    this.policyMode = PolicyMode.ask,
    this.workspace,
    this.lastPromptTokens,
    this.lastCompletionTokens,
    this.contextLength,
    this.compactionSummary,
    this.compactedUntilSeq = 0,
    this.currentRevisionId,
    this.draft = ChatDraft.empty,
    this.messageEdits = const {},
    this.draftRevision = 0,
    this.messageEditsRevision = 0,
    this.revision = 0,
  });

  final String id;
  final String hostId;
  final ChatKind kind;

  /// Непосредственный родитель для скрытого чата субагента.
  final String? parentChatId;

  /// Самый верхний пользовательский чат. Для обычного чата null.
  final String? rootChatId;

  /// Глубина вложенности субагента; у обычного чата 0.
  final int depth;

  bool get isSubagent => kind == ChatKind.subagent;

  /// Проект чата. Null, пока папка не выбрана и хост не задаёт свою:
  /// неявный домашний каталог общим проектом не становится.
  final String? projectId;
  final String title;
  final ChatTitleSource titleSource;
  final String? model;

  /// Уровень рассуждений чата. [ReasoningPreference.inherit] — следовать
  /// настройке по умолчанию из Settings.
  final ReasoningPreference reasoning;
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

  /// Неотправленные правки сообщений этого чата. Живут отдельно от черновика композера:
  /// пузырь показывает этот текст и окрашен, пока правку не отправят.
  final Map<String, ChatDraft> messageEdits;

  /// Версия черновика композера. Растёт при каждом сохранении.
  final int draftRevision;

  /// Версия неотправленных правок сообщений. Отдельная от черновика:
  /// правки и набор в поле ввода не должны конфликтовать без причины.
  final int messageEditsRevision;

  /// Версия метаданных чата (заголовок, модель, политика, workspace).
  /// Нужна для точечного PATCH без затирания чужих изменений.
  final int revision;

  Chat copyWith({
    String? id,
    String? hostId,
    ChatKind? kind,
    String? parentChatId,
    String? rootChatId,
    int? depth,
    String? projectId,
    bool clearProjectId = false,
    String? title,
    ChatTitleSource? titleSource,
    String? model,
    ReasoningPreference? reasoning,
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
    Map<String, ChatDraft>? messageEdits,
    int? draftRevision,
    int? messageEditsRevision,
    int? revision,
  }) => Chat(
    id: id ?? this.id,
    hostId: hostId ?? this.hostId,
    kind: kind ?? this.kind,
    parentChatId: parentChatId ?? this.parentChatId,
    rootChatId: rootChatId ?? this.rootChatId,
    depth: depth ?? this.depth,
    projectId: clearProjectId ? null : (projectId ?? this.projectId),
    title: title ?? this.title,
    titleSource: titleSource ?? this.titleSource,
    model: model ?? this.model,
    reasoning: reasoning ?? this.reasoning,
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
    messageEdits: messageEdits ?? this.messageEdits,
    draftRevision: draftRevision ?? this.draftRevision,
    messageEditsRevision: messageEditsRevision ?? this.messageEditsRevision,
    revision: revision ?? this.revision,
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
    this.mentions = const [],
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
      mentions: [
        for (final m in (map['mentions'] as List? ?? const []))
          MentionRef.fromJson(m as Map<String, dynamic>),
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

  /// Упоминания файлов и каталогов workspace. Диапазоны указывают на [text].
  final List<MentionRef> mentions;
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
    List<MentionRef>? mentions,
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
    mentions: mentions ?? this.mentions,
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
    'mentions': [for (final m in mentions) m.toJson()],
  });
}

/// Состояние запуска инструмента, а не его результата.
///
/// [done] значит, что вызов состоялся и завершился. Успешным ли был результат,
/// решает [ToolRun.resultError]. [failed] — сбой самого вызова: инструмент не
/// удалось запустить или довести до результата из-за ошибки в коде, ограничения
/// процесса или потерянной связи. Ошибка инструмента сюда не попадает.
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
    this.resultError = false,
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

  /// Инструмент выполнился, но вернул ошибку: ненулевой код выхода, неверные
  /// аргументы или ошибка операции. Это нормальный результат, который агент
  /// обрабатывает; для интерфейса это не сбой вызова.
  final bool resultError;

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
    bool? resultError,
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
    resultError: resultError ?? this.resultError,
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
