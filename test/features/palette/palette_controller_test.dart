import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/palette/domain/command_registry.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:probably_works/features/palette/presentation/palette_controller.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/search.dart';

final class _FakeSearchApi implements AgentApi {
  final queries = <SearchQuery>[];
  var hits = <SearchHit>[];

  @override
  Future<List<SearchHit>> search(SearchQuery query) async {
    queries.add(query);
    return hits;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('AgentApi is not used in palette tests');
}

CommandRegistry _registry() => CommandRegistry([
  PaletteCommand(
    id: 'alpha',
    titles: const LocalizedText(ru: 'Альфа', en: 'Alpha'),
    keywords: const LocalizedText(ru: 'первая', en: 'first'),
    action: const BuiltinPaletteAction('alpha'),
  ),
]);

void main() {
  final now = DateTime.utc(2026, 11, 13);
  final project = Project(
    id: 'p1',
    hostId: 'local',
    name: 'Work',
    workspace: '/work',
    workspaceKey: '/work',
    createdAt: now,
    updatedAt: now,
  );
  final chat = Chat(
    id: 'c1',
    hostId: 'local',
    projectId: 'p1',
    title: 'Review',
    createdAt: now,
    updatedAt: now,
  );

  PaletteController controller(_FakeSearchApi api) => PaletteController(
    registry: _registry(),
    searchApi: api,
    projects: [project],
    chats: [chat],
    languageCode: 'ru',
    currentChatId: 'c1',
    currentProjectId: 'p1',
  );

  test('@command does not call the chat search', () async {
    final api = _FakeSearchApi();
    final palette = controller(api);
    addTearDown(palette.dispose);

    palette.setRaw('@command альфа');
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(api.queries, isEmpty);
    expect(palette.results.first.command?.id, 'alpha');
  });

  test(
    'project filter resolves the name and scopes the server search',
    () async {
      final api = _FakeSearchApi();
      final palette = controller(api);
      addTearDown(palette.dispose);

      palette.setRaw('@project:"Work" альфа');
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(api.queries, hasLength(1));
      expect(api.queries.single.projectId, 'p1');
      expect(api.queries.single.scope, SearchScope.project);
    },
  );

  test('@current scopes the server search to the open chat', () async {
    final api = _FakeSearchApi();
    final palette = controller(api);
    addTearDown(palette.dispose);

    palette.setRaw('@current альфа');
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(api.queries.single.chatId, 'c1');
    expect(api.queries.single.scope, SearchScope.chat);
  });

  test('unknown project is an error and does not hit the server', () async {
    final api = _FakeSearchApi();
    final palette = controller(api);
    addTearDown(palette.dispose);

    palette.setRaw('@project:"Missing" альфа');
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(palette.query.errors, contains(PaletteQueryError.projectNotFound));
    expect(api.queries, isEmpty);
    expect(palette.results, isNotEmpty);
  });

  test('merges command and chat results by score', () async {
    final api = _FakeSearchApi()
      ..hits = const [
        SearchHit(
          kind: SearchHitKind.chat,
          title: 'Review',
          chatId: 'c1',
          chatTitle: 'Review',
          score: 0.8,
        ),
      ];
    final palette = controller(api);
    addTearDown(palette.dispose);

    palette.setRaw('альфа');
    await Future<void>.delayed(const Duration(milliseconds: 250));

    expect(palette.results, hasLength(2));
    expect(palette.results.first.kind, PaletteResultKind.command);
    expect(palette.results.last.kind, PaletteResultKind.chat);
  });

  test('the first arrow reveals the first row instead of skipping it', () {
    final palette = PaletteController(
      registry: CommandRegistry([
        PaletteCommand(
          id: 'alpha',
          titles: const LocalizedText(ru: 'Альфа', en: 'Alpha'),
          action: const BuiltinPaletteAction('alpha'),
        ),
        PaletteCommand(
          id: 'beta',
          titles: const LocalizedText(ru: 'Бета', en: 'Beta'),
          action: const BuiltinPaletteAction('beta'),
        ),
      ]),
      searchApi: _FakeSearchApi(),
      projects: const [],
      chats: const [],
      languageCode: 'en',
    );
    addTearDown(palette.dispose);

    expect(palette.selectionVisible, isFalse);
    palette.moveSelection(1);

    expect(palette.selectionVisible, isTrue);
    expect(palette.selected, 0);

    palette.moveSelection(1);
    expect(palette.selected, 1);
  });
}
