import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:pw_agent/agent/domain/search.dart';
import 'package:pw_agent/core/util/char_substring.dart';

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

    var index = 0;
    while (index < raw.length) {
      final char = raw[index];
      final atTokenStart =
          char == '@' && (index == 0 || _isSpace(raw[index - 1]));
      if (!atTokenStart) {
        text.write(char);
        index++;
        continue;
      }

      final end = _tokenEnd(raw, index);
      final token = charRange(raw, index, end);
      index = end;
      final split = token.indexOf(':');
      final name = (split < 0 ? charFrom(token, 1) : charRange(token, 1, split))
          .toLowerCase();
      final canonical = _aliases[name];
      if (canonical == null) {
        _appendText(text, token);
        continue;
      }
      final value = split < 0
          ? ''
          : _unquote(charFrom(token, split + 1).trim());

      switch (canonical) {
        case 'command':
          if (value.isNotEmpty) {
            _appendText(text, token);
            break;
          }
          commandsOnly = true;
          filters.add(
            PaletteFilter(kind: PaletteFilterKind.command, raw: token),
          );
        case 'project':
          if (value.isEmpty) {
            if (context.currentProjectId == null) {
              _appendText(text, token);
              break;
            }
            projectId = context.currentProjectId;
            filters.add(
              PaletteFilter(kind: PaletteFilterKind.currentProject, raw: token),
            );
            break;
          }
          projectName = value;
          projectId = null;
          filters.add(
            PaletteFilter(
              kind: PaletteFilterKind.project,
              raw: token,
              value: value,
            ),
          );
        case 'current':
          if (value.isNotEmpty || context.currentChatId == null) {
            _appendText(text, token);
            break;
          }
          if (explicitChat) break;
          currentChat = true;
          chatId = context.currentChatId;
          filters.add(
            PaletteFilter(kind: PaletteFilterKind.current, raw: token),
          );
        case 'current-project':
          if (value.isNotEmpty || context.currentProjectId == null) {
            _appendText(text, token);
            break;
          }
          projectId = context.currentProjectId;
          filters.add(
            PaletteFilter(kind: PaletteFilterKind.currentProject, raw: token),
          );
        case 'chat':
          if (value.isEmpty) {
            if (context.currentChatId == null) {
              _appendText(text, token);
              break;
            }
            if (explicitChat) break;
            currentChat = true;
            chatId = context.currentChatId;
            filters.add(
              PaletteFilter(kind: PaletteFilterKind.current, raw: token),
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
              raw: token,
              value: value,
            ),
          );
        case 'scope':
          final parsed = SearchScope.values.asNameMap()[value];
          if (parsed == null) {
            _appendText(text, token);
            break;
          }
          if (parsed == SearchScope.chat) {
            if (!explicitChat) {
              if (context.currentChatId == null) {
                _appendText(text, token);
                break;
              }
              currentChat = true;
              chatId = context.currentChatId;
            }
          } else if (parsed == SearchScope.project) {
            if (context.currentProjectId == null) {
              _appendText(text, token);
              break;
            }
            projectId = context.currentProjectId;
          }
          scope = parsed;
          filters.add(
            PaletteFilter(
              kind: PaletteFilterKind.scope,
              raw: token,
              value: value,
            ),
          );
      }
    }

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

  /// Конец @-токена. Кавычки защищают пробелы; `\"` не закрывает кавычку.
  static int _tokenEnd(String raw, int start) {
    var quoted = false;
    var escaped = false;
    for (var i = start + 1; i < raw.length; i++) {
      final char = raw[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == r'\') {
        escaped = true;
        continue;
      }
      if (char == '"') {
        quoted = !quoted;
        continue;
      }
      if (!quoted && _isSpace(char)) return i;
    }
    return raw.length;
  }

  static String _unquote(String value) {
    if (value.length < 2 || !value.startsWith('"') || !value.endsWith('"')) {
      return value;
    }
    final body = charRange(value, 1, value.length - 1);
    return body.replaceAll(r'\"', '"');
  }

  static bool _isSpace(String char) => char.trim().isEmpty;
}
