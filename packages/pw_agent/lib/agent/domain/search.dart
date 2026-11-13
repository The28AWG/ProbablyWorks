import 'package:equatable/equatable.dart';

/// Область поиска по чатам.
enum SearchScope { chat, project, all }

/// Что именно нашлось: чат по названию или сообщение в чате.
enum SearchHitKind { chat, message }

/// Запрос поиска по чатам. Выполняется на сервере/в локальном backend.
class SearchQuery extends Equatable {
  const SearchQuery({
    required this.text,
    this.scope = SearchScope.all,
    this.projectId,
    this.chatId,
    this.limit = 20,
  });

  final String text;
  final SearchScope scope;
  final String? projectId;
  final String? chatId;
  final int limit;

  @override
  List<Object?> get props => [text, scope, projectId, chatId, limit];
}

/// Один результат поиска. Сниппет уже обрезан сервером.
class SearchHit extends Equatable {
  const SearchHit({
    required this.kind,
    required this.title,
    required this.score,
    this.chatId,
    this.chatTitle,
    this.projectId,
    this.messageId,
    this.seq,
    this.snippet,
  });

  final SearchHitKind kind;

  /// Заголовок результата: название чата или фрагмент сообщения.
  final String title;
  final double score;
  final String? chatId;
  final String? chatTitle;
  final String? projectId;
  final String? messageId;
  final int? seq;
  final String? snippet;

  @override
  List<Object?> get props => [
    kind,
    title,
    score,
    chatId,
    chatTitle,
    projectId,
    messageId,
    seq,
    snippet,
  ];
}
