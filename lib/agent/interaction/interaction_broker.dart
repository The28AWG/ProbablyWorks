import 'dart:async';
import 'dart:convert';

import 'package:injectable/injectable.dart';

/// Запрос на подтверждение действия (run_command / write_file / edit_file / trust).
class ApprovalRequest {
  const ApprovalRequest({
    required this.id,
    required this.chatId,
    required this.toolName,
    required this.summary,
    required this.reason,
    this.diff,
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
  const PendingCard({required this.summary, required this.reason, this.diff});

  /// Команда или путь, как на карточке.
  final String summary;

  /// Почему нужно подтверждение.
  final String reason;

  /// Построчный diff для записи файла. Пустая строка не хранится.
  final String? diff;

  /// JSON для колонки `pending_card`.
  String encode() => jsonEncode({
    'summary': summary,
    'reason': reason,
    if (diff != null && diff!.isNotEmpty) 'diff': diff,
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
      return PendingCard(
        summary: summary,
        reason: reason,
        diff: diff is String && diff.isNotEmpty ? diff : null,
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
  final Map<String, Completer<bool>> _approvals = {};
  final Map<String, Completer<String?>> _answers = {};
  final Map<String, ApprovalRequest> _pendingApprovals = {};
  final Map<String, UserQuestion> _pendingQuestions = {};

  Stream<ApprovalRequest> get approvalRequests => _approvalRequests.stream;

  Stream<UserQuestion> get questions => _questions.stream;

  List<ApprovalRequest> pendingApprovals(String chatId) => [
    for (final r in _pendingApprovals.values)
      if (r.chatId == chatId) r,
  ];

  List<UserQuestion> pendingQuestions(String chatId) => [
    for (final q in _pendingQuestions.values)
      if (q.chatId == chatId) q,
  ];

  Future<bool> requestApproval(ApprovalRequest request) {
    final completer = Completer<bool>();
    _approvals[request.id] = completer;
    _pendingApprovals[request.id] = request;
    _approvalRequests.add(request);
    return completer.future;
  }

  void resolveApproval(String requestId, {required bool allow}) {
    _pendingApprovals.remove(requestId);
    final completer = _approvals.remove(requestId);
    if (completer != null && !completer.isCompleted) completer.complete(allow);
  }

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

  /// Stop: все ожидания чата получают отказ/пустой ответ, чтобы цикл агента завершился.
  void cancelChat(String chatId) {
    for (final request in pendingApprovals(chatId)) {
      resolveApproval(request.id, allow: false);
    }
    for (final question in pendingQuestions(chatId)) {
      answer(question.id, null);
    }
  }
}
