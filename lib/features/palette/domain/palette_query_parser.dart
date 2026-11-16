import 'package:probably_works/core/util/at_query.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:pw_agent/agent/domain/search.dart';

/// Контекст, который нужен фильтрам `@current` и `@scope`.
class PaletteParseContext {
  const PaletteParseContext({this.currentChatId, this.currentProjectId});

  final String? currentChatId;
  final String? currentProjectId;
}

/// Разбор строки палитры: свободный текст + фильтры `@...`.
///
/// Фильтры не попадают в текстовый запрос. Фильтр, который нельзя применить
/// (неизвестное имя, нет открытого чата, неверный scope), остаётся обычным
/// текстом: палитра не показывает ошибок, просто ищет как есть.
abstract final class PaletteQueryParser {
  const PaletteQueryParser._();

  static const _aliases = <String, String>{
    'command': 'command',
    'команда': 'command',
    'project': 'project',
    'проект': 'project',
    'current': 'current',
    'текущий': 'current',
    'current-project': 'current-project',
    'текущий-проект': 'current-project',
    'chat': 'chat',
    'чат': 'chat',
    'scope': 'scope',
    'область': 'scope',
  };

  static PaletteQuery parse(
    String raw, {
    PaletteParseContext context = const PaletteParseContext(),
  }) {
    final text = StringBuffer();
    final filters = <PaletteFilter>[];
    var commandsOnly = false;
    var scope = SearchScope.all;
    String? projectId;
    String? projectName;
    String? chatId;
    String? chatName;
    var currentChat = false;
    var explicitChat = false;

    // Токены разбираются общей утилитой, а всё, что между ними, остаётся текстом.
    var cursor = 0;
    for (final token in AtQuery.tokens(raw)) {
      text.write(AtQuery.textOf(raw, cursor, token.start));
      cursor = token.end;
      final canonical = _aliases[token.name];
      if (canonical == null) {
        _appendText(text, token.raw);
        continue;
      }
      final value = token.value;

      switch (canonical) {
        case 'command':
          if (value.isNotEmpty) {
            _appendText(text, token.raw);
            break;
          }
          commandsOnly = true;
          filters.add(
            PaletteFilter(kind: PaletteFilterKind.command, raw: token.raw),
          );
        case 'project':
          if (value.isEmpty) {
            if (context.currentProjectId == null) {
              _appendText(text, token.raw);
              break;
            }
            projectId = context.currentProjectId;
            filters.add(
              PaletteFilter(
                kind: PaletteFilterKind.currentProject,
                raw: token.raw,
              ),
            );
            break;
          }
          projectName = value;
          projectId = null;
          filters.add(
            PaletteFilter(
              kind: PaletteFilterKind.project,
              raw: token.raw,
              value: value,
            ),
          );
        case 'current':
          if (value.isNotEmpty || context.currentChatId == null) {
            _appendText(text, token.raw);
            break;
          }
          if (explicitChat) break;
          currentChat = true;
          chatId = context.currentChatId;
          filters.add(
            PaletteFilter(kind: PaletteFilterKind.current, raw: token.raw),
          );
        case 'current-project':
          if (value.isNotEmpty || context.currentProjectId == null) {
            _appendText(text, token.raw);
            break;
          }
          projectId = context.currentProjectId;
          filters.add(
            PaletteFilter(
              kind: PaletteFilterKind.currentProject,
              raw: token.raw,
            ),
          );
        case 'chat':
          if (value.isEmpty) {
            if (context.currentChatId == null) {
              _appendText(text, token.raw);
              break;
            }
            if (explicitChat) break;
            currentChat = true;
            chatId = context.currentChatId;
            filters.add(
              PaletteFilter(kind: PaletteFilterKind.current, raw: token.raw),
            );
            break;
          }
          explicitChat = true;
          currentChat = false;
          chatName = value;
          chatId = null;
          filters.add(
            PaletteFilter(
              kind: PaletteFilterKind.chat,
              raw: token.raw,
              value: value,
            ),
          );
        case 'scope':
          final parsed = SearchScope.values.asNameMap()[value];
          if (parsed == null) {
            _appendText(text, token.raw);
            break;
          }
          if (parsed == SearchScope.chat) {
            if (!explicitChat) {
              if (context.currentChatId == null) {
                _appendText(text, token.raw);
                break;
              }
              currentChat = true;
              chatId = context.currentChatId;
            }
          } else if (parsed == SearchScope.project) {
            if (context.currentProjectId == null) {
              _appendText(text, token.raw);
              break;
            }
            projectId = context.currentProjectId;
          }
          scope = parsed;
          filters.add(
            PaletteFilter(
              kind: PaletteFilterKind.scope,
              raw: token.raw,
              value: value,
            ),
          );
      }
    }
    text.write(AtQuery.textOf(raw, cursor, raw.length));

    return PaletteQuery(
      text: text.toString().replaceAll(RegExp(r'\s+'), ' ').trim(),
      commandsOnly: commandsOnly,
      scope: _scopeFor(
        scope,
        commandsOnly: commandsOnly,
        currentChat: currentChat,
        chatId: chatId,
        chatName: chatName,
        projectId: projectId,
        projectName: projectName,
      ),
      projectId: projectId,
      projectName: projectName,
      chatId: chatId,
      chatName: chatName,
      currentChat: currentChat,
      filters: filters,
    );
  }

  /// Возвращает неподходящий фильтр в текст запроса: так он ничем не
  /// отличается от любого другого слова.
  static void _appendText(StringBuffer text, String token) {
    text
      ..write(token)
      ..write(' ');
  }

  static SearchScope _scopeFor(
    SearchScope scope, {
    required bool commandsOnly,
    required bool currentChat,
    required String? chatId,
    required String? chatName,
    required String? projectId,
    required String? projectName,
  }) {
    if (commandsOnly) return scope;
    if (currentChat || chatId != null || chatName != null) {
      return SearchScope.chat;
    }
    if (projectId != null || projectName != null) return SearchScope.project;
    return scope;
  }
}
