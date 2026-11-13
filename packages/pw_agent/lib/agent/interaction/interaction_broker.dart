import 'dart:async';
import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/interaction/edit_file_changes_request.dart';

/// Что пользователь выбрал в карточке подтверждения.
enum ApprovalAction { deny, allowOnce, allowTurn, allowChat }

/// Решение по карточке. [reason] заполняется только для отказа с пояснением.
final class ApprovalDecision {
  const ApprovalDecision.deny({this.reason}) : action = ApprovalAction.deny;

  const ApprovalDecision.allowOnce()
    : action = ApprovalAction.allowOnce,
      reason = null;

  const ApprovalDecision.allowTurn()
    : action = ApprovalAction.allowTurn,
      reason = null;

  const ApprovalDecision.allowChat()
    : action = ApprovalAction.allowChat,
      reason = null;

  final ApprovalAction action;
  final String? reason;

  bool get allowed => action != ApprovalAction.deny;
}

/// Запрос на подтверждение действия (run_command / write_file / edit_file / trust).
class ApprovalRequest {
  const ApprovalRequest({
    required this.id,
    required this.chatId,
    required this.toolName,
    required this.summary,
    required this.reason,
    this.diff,
    this.turnId,
    this.permissionKey,
    this.grantable = true,
  });

  final String id;
  final String chatId;
  final String toolName;

  /// Текст для карточки: команда или путь файла.
  final String summary;

  /// Почему нужен approve (Ask-правило).
  final String reason;

  /// Построчный diff для write/edit, если применимо.
  final String? diff;

  /// Пользовательское сообщение, в рамках которого действует разрешение «для хода».
  final String? turnId;

  /// Точный ключ разрешения: инструмент + то, что показано в карточке.
  final String? permissionKey;

  /// Можно ли выдать разрешение на ход или чат.
  final bool grantable;
}

/// Вопрос агента пользователю (ask_user).
class UserQuestion {
  const UserQuestion({
    required this.id,
    required this.chatId,
    required this.text,
  });

  final String id;
  final String chatId;
  final String text;
}

/// Текст карточки подтверждения, который нужно показать снова после перезапуска.
/// В базе лежит JSON в поле pendingCard запуска, пока его статус — waitingApproval.
class PendingCard {
  const PendingCard({
    required this.summary,
    required this.reason,
    this.diff,
    this.turnId,
    this.permissionKey,
    this.grantable = true,
  });

  /// Команда или путь, как на карточке.
  final String summary;

  /// Почему нужно подтверждение.
  final String reason;

  /// Построчный diff для записи файла. Пустая строка не хранится.
  final String? diff;

  /// Ход и точный ключ нужны, чтобы после перезапуска работали области
  /// «для хода» и «для чата».
  final String? turnId;
  final String? permissionKey;
  final bool grantable;

  /// JSON для колонки `pending_card`.
  String encode() => jsonEncode({
    'summary': summary,
    'reason': reason,
    if (diff != null && diff!.isNotEmpty) 'diff': diff,
    if (turnId != null) 'turnId': turnId,
    if (permissionKey != null) 'permissionKey': permissionKey,
    if (!grantable) 'grantable': false,
  });

  /// Разбирает JSON карточки. Битый или пустой текст даёт null: карточку всё равно можно
  /// собрать из команды запуска, но без причины и diff.
  static PendingCard? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final summary = json['summary'];
      final reason = json['reason'];
      if (summary is! String || reason is! String) return null;
      final diff = json['diff'];
      final turnId = json['turnId'];
      final permissionKey = json['permissionKey'];
      final grantable = json['grantable'];
      return PendingCard(
        summary: summary,
        reason: reason,
        diff: diff is String && diff.isNotEmpty ? diff : null,
        turnId: turnId is String && turnId.isNotEmpty ? turnId : null,
        permissionKey: permissionKey is String && permissionKey.isNotEmpty
            ? permissionKey
            : null,
        grantable: grantable != false,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Единая точка ожидания решений пользователя. Агент ждёт [requestApproval]/[askUser];
/// UI отвечает через [resolveApproval]/[answer]. Stop отменяет все ожидания чата.
///
/// Сами карты живут только в памяти процесса. Долгая отметка «ответа ещё не было» —
/// статус ToolRun `waitingUser` / `waitingApproval`. Пока он такой, открытие чата
/// регистрирует карточку здесь заново. Отказ, ответ и остановка хода меняют статус,
/// и карточка больше не появляется.
@singleton
class InteractionBroker {
  final _approvalRequests = StreamController<ApprovalRequest>.broadcast();
  final _questions = StreamController<UserQuestion>.broadcast();
  final _editFileChangesRequests =
      StreamController<EditFileChangesRequest>.broadcast();
  final Map<String, Completer<ApprovalDecision>> _approvals = {};
  final Map<String, Completer<String?>> _answers = {};
  final Map<String, Completer<EditFileChangesChoice>> _editFileChanges = {};
  final Map<String, ApprovalRequest> _pendingApprovals = {};
  final Map<String, UserQuestion> _pendingQuestions = {};
  final Map<String, EditFileChangesRequest> _pendingEditFileChanges = {};

  /// Разрешения «для хода» и «для чата». Ключ — точная пара инструмента и
  /// текста карточки; широких шаблонов здесь нет.
  final Map<String, Set<String>> _turnGrants = {};
  final Map<String, Set<String>> _chatGrants = {};

  Stream<ApprovalRequest> get approvalRequests => _approvalRequests.stream;

  Stream<UserQuestion> get questions => _questions.stream;

  Stream<EditFileChangesRequest> get editFileChangesRequests =>
      _editFileChangesRequests.stream;

  /// Чаты, в которых есть хотя бы одна неотвеченная карточка.
  Set<String> get waitingChatIds => {
    for (final request in _pendingApprovals.values) request.chatId,
    for (final question in _pendingQuestions.values) question.chatId,
    for (final request in _pendingEditFileChanges.values) request.chatId,
  };

  List<ApprovalRequest> pendingApprovals(String chatId) => [
    for (final r in _pendingApprovals.values)
      if (r.chatId == chatId) r,
  ];

  List<UserQuestion> pendingQuestions(String chatId) => [
    for (final q in _pendingQuestions.values)
      if (q.chatId == chatId) q,
  ];

  List<EditFileChangesRequest> pendingEditFileChanges(String chatId) => [
    for (final request in _pendingEditFileChanges.values)
      if (request.chatId == chatId) request,
  ];

  Future<ApprovalDecision> requestApproval(ApprovalRequest request) {
    final completer = Completer<ApprovalDecision>();
    _approvals[request.id] = completer;
    _pendingApprovals[request.id] = request;
    _approvalRequests.add(request);
    return completer.future;
  }

  /// Записывает решение и, если разрешение выдано на ход или чат, запоминает
  /// точный ключ. Широких разрешений нет: изменившаяся команда спросит снова.
  void resolveApproval(String requestId, ApprovalDecision decision) {
    final request = _pendingApprovals.remove(requestId);
    final completer = _approvals.remove(requestId);
    if (decision.allowed && request != null && request.grantable) {
      final key = request.permissionKey;
      if (key != null && key.isNotEmpty) {
        if (decision.action == ApprovalAction.allowTurn &&
            request.turnId != null) {
          _turnGrants.putIfAbsent(request.turnId!, () => {}).add(key);
        } else if (decision.action == ApprovalAction.allowChat) {
          _chatGrants.putIfAbsent(request.chatId, () => {}).add(key);
        }
      }
    }
    if (completer != null && !completer.isCompleted) {
      completer.complete(decision);
    }
  }

  /// Есть ли уже разрешение на этот точный ключ в ходе или чате.
  bool hasGrant({
    required String chatId,
    required String? turnId,
    required String key,
  }) {
    if (turnId != null && (_turnGrants[turnId]?.contains(key) ?? false)) {
      return true;
    }
    return _chatGrants[chatId]?.contains(key) ?? false;
  }

  /// Сбрасывает разрешения чата при удалении и разрешения хода при правке.
  void clearChatGrants(String chatId) => _chatGrants.remove(chatId);

  void clearTurnGrants(String turnId) => _turnGrants.remove(turnId);

  Future<String?> askUser(String chatId, String id, String text) {
    final completer = Completer<String?>();
    final question = UserQuestion(id: id, chatId: chatId, text: text);
    _answers[id] = completer;
    _pendingQuestions[id] = question;
    _questions.add(question);
    return completer.future;
  }

  void answer(String questionId, String? text) {
    _pendingQuestions.remove(questionId);
    final completer = _answers.remove(questionId);
    if (completer != null && !completer.isCompleted) completer.complete(text);
  }

  /// Спросить, откатывать ли файлы перед правкой или укорочением истории.
  Future<EditFileChangesChoice> requestEditFileChanges(
    EditFileChangesRequest request,
  ) {
    final completer = Completer<EditFileChangesChoice>();
    _editFileChanges[request.id] = completer;
    _pendingEditFileChanges[request.id] = request;
    _editFileChangesRequests.add(request);
    return completer.future;
  }

  void resolveEditFileChanges(String requestId, EditFileChangesChoice choice) {
    _pendingEditFileChanges.remove(requestId);
    final completer = _editFileChanges.remove(requestId);
    if (completer != null && !completer.isCompleted) completer.complete(choice);
  }

  /// Stop: все ожидания чата получают отказ/пустой ответ, чтобы цикл агента завершился.
  void cancelChat(String chatId) {
    for (final request in pendingApprovals(chatId)) {
      resolveApproval(request.id, const ApprovalDecision.deny());
    }
    for (final question in pendingQuestions(chatId)) {
      answer(question.id, null);
    }
    for (final request in pendingEditFileChanges(chatId)) {
      resolveEditFileChanges(request.id, EditFileChangesChoice.cancel);
    }
  }
}
