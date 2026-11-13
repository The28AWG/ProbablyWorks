import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:probably_works/features/palette/domain/palette_query_parser.dart';
import 'package:pw_agent/agent/domain/search.dart';

void main() {
  const context = PaletteParseContext(
    currentChatId: 'chat-1',
    currentProjectId: 'project-1',
  );

  test('parses @command and keeps the free text', () {
    final query = PaletteQueryParser.parse(
      '@command настройки',
      context: context,
    );

    expect(query.text, 'настройки');
    expect(query.commandsOnly, isTrue);
    expect(query.filters.single.kind, PaletteFilterKind.command);
  });

  test('parses a quoted project name and scopes the search', () {
    final query = PaletteQueryParser.parse(
      '@project:"Project Name" миграция',
      context: context,
    );

    expect(query.text, 'миграция');
    expect(query.projectName, 'Project Name');
    expect(query.scope, SearchScope.project);
    expect(query.filters.single.kind, PaletteFilterKind.project);
  });

  test('parses @current and @chat', () {
    final current = PaletteQueryParser.parse(
      '@current память',
      context: context,
    );
    expect(current.text, 'память');
    expect(current.currentChat, isTrue);
    expect(current.chatId, 'chat-1');
    expect(current.scope, SearchScope.chat);

    final named = PaletteQueryParser.parse(
      '@chat:"Ревью" ошибка',
      context: context,
    );
    expect(named.chatName, 'Ревью');
    expect(named.scope, SearchScope.chat);
    expect(named.chatId, isNull);
  });

  test('turns unusable filters into plain text', () {
    final noChat = PaletteQueryParser.parse('@current память');
    expect(noChat.text, '@current память');
    expect(noChat.currentChat, isFalse);

    final unknown = PaletteQueryParser.parse(
      '@unknown текст',
      context: context,
    );
    expect(unknown.text, '@unknown текст');

    final badScope = PaletteQueryParser.parse(
      '@scope:everything текст',
      context: context,
    );
    expect(badScope.text, '@scope:everything текст');
    expect(badScope.scope, SearchScope.all);

    final noProject = PaletteQueryParser.parse('@project: текст');
    expect(noProject.text, '@project: текст');
    expect(noProject.projectId, isNull);
  });

  test('supports localized aliases and explicit scope', () {
    final query = PaletteQueryParser.parse(
      '@команда @область:all настройки',
      context: context,
    );

    expect(query.commandsOnly, isTrue);
    expect(query.text, 'настройки');
    expect(query.scope, SearchScope.all);
  });

  test('keeps escaped quotes inside a project name', () {
    final query = PaletteQueryParser.parse(
      r'@project:"Project \"A\"" текст',
      context: context,
    );

    expect(query.projectName, 'Project "A"');
    expect(query.text, 'текст');
  });
}
