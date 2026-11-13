part of 'chat_bloc.dart';

// ---- events -----------------------------------------------------------------

sealed class ChatEvent extends Equatable {
  const ChatEvent();

  @override
  List<Object?> get props => [];
}

/// Открытие чата: существующего или нового. Такие события идут по очереди (см. [ChatBloc]).
sealed class ChatOpenEvent extends ChatEvent {
  const ChatOpenEvent();
}

final class ChatOpened extends ChatOpenEvent {
  const ChatOpened(this.chatId, {this.seedChat, this.seedHosts = const []});

  final String chatId;

  /// Чат из уже загруженного списка (см. [ChatBloc]): показывается сразу, до чтения данных.
  final Chat? seedChat;
  final List<Host> seedHosts;

  @override
  List<Object?> get props => [chatId];
}

/// Текст в поле ввода изменился (набор, вставка, очистка). Состояние не меняется, чтобы каждый символ
/// не перерисовывал экран: блок только запоминает черновик.
final class ChatDraftEdited extends ChatEvent {
  const ChatDraftEdited(this.text);

  final String text;

  @override
  List<Object?> get props => [text];
}

/// К черновику добавлены вложения (файлы уже прочитаны). Сверх лимита сообщения отбрасываются.
final class ChatAttachmentsAdded extends ChatEvent {
  const ChatAttachmentsAdded(this.items);

  final List<AttachmentRef> items;

  @override
  List<Object?> get props => [items];
}

final class ChatAttachmentRemoved extends ChatEvent {
  const ChatAttachmentRemoved(this.index);

  final int index;

  @override
  List<Object?> get props => [index];
}

final class ChatSubmitted extends ChatEvent {
  const ChatSubmitted(
    this.text, {
    this.attachments = const [],
    this.sendNow = false,
  });

  final String text;
  final List<AttachmentRef> attachments;
  final bool sendNow;
}

final class ChatStopped extends ChatEvent {
  const ChatStopped();
}

final class ChatContinued extends ChatEvent {
  const ChatContinued();
}

final class ChatRegenerateRequested extends ChatEvent {
  const ChatRegenerateRequested();
}

final class ChatForkRequested extends ChatEvent {
  const ChatForkRequested(this.messageId, {this.title});

  final String messageId;
  final String? title;

  @override
  List<Object?> get props => [messageId, title];
}

final class ChatApprovalAnswered extends ChatEvent {
  const ChatApprovalAnswered(this.requestId, this.decision);

  final String requestId;
  final ApprovalDecision decision;

  @override
  List<Object?> get props => [requestId, decision.action, decision.reason];
}

final class ChatQuestionAnswered extends ChatEvent {
  const ChatQuestionAnswered(this.questionId, this.text);

  final String questionId;
  final String text;

  @override
  List<Object?> get props => [questionId, text];
}

final class ChatMessageEdited extends ChatEvent {
  const ChatMessageEdited(
    this.messageId,
    this.text, {
    this.attachments = const [],
    this.onDone,
  });

  final String messageId;
  final String text;

  /// Вложения нового сообщения. Пустой список отправляет текст без вложений:
  /// композер правки сам решает, что оставить от исходного сообщения.
  final List<AttachmentRef> attachments;

  /// true — история переписана и ход запущен. false — отмена отката файлов или сообщение
  /// не найдено: поле правки нужно оставить. В [props] нет: это не данные события.
  final void Function(bool accepted)? onDone;

  @override
  List<Object?> get props => [messageId, text, attachments];
}

final class ChatDeletedAfter extends ChatEvent {
  const ChatDeletedAfter(this.messageId);

  final String messageId;

  @override
  List<Object?> get props => [messageId];
}

final class ChatModelChanged extends ChatEvent {
  const ChatModelChanged(this.model);

  final LlmModelInfo model;

  @override
  List<Object?> get props => [model.id];
}

final class ChatPolicyChanged extends ChatEvent {
  const ChatPolicyChanged(this.mode);

  final PolicyMode mode;

  @override
  List<Object?> get props => [mode];
}

final class ChatHostChanged extends ChatEvent {
  const ChatHostChanged(this.hostId);

  final String hostId;

  @override
  List<Object?> get props => [hostId];
}

final class ChatWorkspaceChanged extends ChatEvent {
  const ChatWorkspaceChanged(this.workspace);

  final String? workspace;

  @override
  List<Object?> get props => [workspace];
}

final class ChatWorkspaceTrusted extends ChatEvent {
  const ChatWorkspaceTrusted();
}

final class ChatRunStopRequested extends ChatEvent {
  const ChatRunStopRequested(this.runId);

  final String runId;

  @override
  List<Object?> get props => [runId];
}

final class ChatEditFileChangesAnswered extends ChatEvent {
  const ChatEditFileChangesAnswered(this.requestId, this.choice);

  final String requestId;
  final EditFileChangesChoice choice;

  @override
  List<Object?> get props => [requestId, choice];
}

/// Элемент очереди: отправить сейчас (прерывает текущий шаг модели).
final class ChatQueueSendNow extends ChatEvent {
  const ChatQueueSendNow(this.index);

  final int index;

  @override
  List<Object?> get props => [index];
}

/// Элемент очереди: удалить.
final class ChatQueueRemoved extends ChatEvent {
  const ChatQueueRemoved(this.index);

  final int index;

  @override
  List<Object?> get props => [index];
}

/// Элемент очереди: вернуть текст в поле ввода для правки.
final class ChatQueueEdited extends ChatEvent {
  const ChatQueueEdited(this.index);

  final int index;

  @override
  List<Object?> get props => [index];
}

/// Новый чат: стартовый экран без записи в БД. Чат создаётся при первой отправке. Черновик текущего
/// чата переносится в новый, а исходный очищается.
final class ChatDraftOpened extends ChatOpenEvent {
  const ChatDraftOpened();
}

/// Закрепить или открепить модель в быстром списке.
final class ChatModelPinToggled extends ChatEvent {
  const ChatModelPinToggled(this.modelId);

  final String modelId;

  @override
  List<Object?> get props => [modelId];
}

/// Дневной лимит трат чата изменён из диалога контекста.
final class ChatDailyBudgetChanged extends ChatEvent {
  const ChatDailyBudgetChanged(this.budgetUsd);

  /// Null — снять лимит.
  final double? budgetUsd;

  @override
  List<Object?> get props => [budgetUsd];
}

/// Ручное сжатие истории (кнопка в контексте).
final class ChatCompactRequested extends ChatEvent {
  const ChatCompactRequested();

  @override
  List<Object?> get props => [];
}

/// Внутренние события: поток из сессии, брокера и шины вывода.
final class _SessionEvent extends ChatEvent {
  const _SessionEvent(this.event);

  final AgentEvent event;
}

final class _LiveChunk extends ChatEvent {
  const _LiveChunk(this.runId, this.text);

  final String runId;
  final String text;

  @override
  List<Object?> get props => [runId, text];
}

final class _LiveFlush extends ChatEvent {
  const _LiveFlush();
}

final class _Refresh extends ChatEvent {
  const _Refresh();
}

/// Каталог моделей изменился (загружен, обновлён в фоне или запомнены детали моделей).
final class _CatalogChanged extends ChatEvent {
  const _CatalogChanged(this.catalog);

  final ModelCatalogState catalog;
}

/// Настройки журнала шагов изменились в Settings: перечитать их, даже если чат уже открыт.
final class _StepsChanged extends ChatEvent {
  const _StepsChanged();
}

/// Закреплённые модели изменились в Settings или в композере другого чата: список выбора обновляется сразу.
final class _PinnedChanged extends ChatEvent {
  const _PinnedChanged();
}

/// Модель по умолчанию изменилась: новый чат без своей модели сразу показывает её.
final class _DefaultModelChanged extends ChatEvent {
  const _DefaultModelChanged();
}

/// Список хостов изменился (добавлен, отредактирован, удалён): меню хостов в композере обновляется сразу.
final class _HostsChanged extends ChatEvent {
  const _HostsChanged(this.hosts);

  final List<Host> hosts;

  @override
  List<Object?> get props => [hosts];
}
