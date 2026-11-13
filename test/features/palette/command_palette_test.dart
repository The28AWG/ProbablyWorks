import 'package:app_ui/app_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/palette/domain/command_registry.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:probably_works/features/palette/presentation/command_palette.dart';
import 'package:probably_works/features/palette/presentation/palette_controller.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/search.dart';

const _labels = PaletteLabels(
  command: 'Commands',
  project: 'Project filter',
  current: 'Current chat',
  currentProject: 'Current project',
  chat: 'Chat filter',
  scope: 'Search scope',
  allChats: 'All chats',
  projectScope: 'Current project',
  chatScope: 'Current chat',
);

final class _NoSearchApi implements AgentApi {
  @override
  Future<List<SearchHit>> search(SearchQuery query) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('AgentApi is not used in palette widget tests');
}

void main() {
  testWidgets('shows commands and runs the selected one', (tester) async {
    final controller = PaletteController(
      registry: CommandRegistry([
        PaletteCommand(
          id: 'alpha',
          titles: const LocalizedText(ru: 'Альфа', en: 'Alpha'),
          action: const BuiltinPaletteAction('alpha'),
        ),
      ]),
      searchApi: _NoSearchApi(),
      projects: const [],
      chats: const [],
      labels: _labels,
      languageCode: 'en',
    );
    addTearDown(controller.dispose);
    PaletteCommand? picked;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CommandPaletteDialog(
            controller: controller,
            onCommand: (command) => picked = command,
            onHit: (_) => throw StateError('unexpected hit'),
            onClose: () => throw StateError('unexpected close'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Alpha'), findsOneWidget);
    await tester.tap(find.text('Alpha'));
    await tester.pump();

    expect(picked?.id, 'alpha');
  });

  testWidgets('a group can be opened and left with the back button', (
    tester,
  ) async {
    final controller = PaletteController(
      registry: CommandRegistry([
        PaletteCommand(
          id: 'nav',
          titles: const LocalizedText(ru: 'Навигация', en: 'Navigation'),
          order: 0,
        ),
        PaletteCommand(
          id: 'nav.chats',
          parentId: 'nav',
          titles: const LocalizedText(ru: 'Чаты', en: 'Chats'),
          action: const BuiltinPaletteAction('chats'),
        ),
      ]),
      searchApi: _NoSearchApi(),
      projects: const [],
      chats: const [],
      labels: _labels,
      languageCode: 'en',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CommandPaletteDialog(
            controller: controller,
            onCommand: (_) => throw StateError('unexpected command'),
            onHit: (_) => throw StateError('unexpected hit'),
            onClose: () => throw StateError('unexpected close'),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Navigation').first);
    await tester.pump();
    expect(find.text('Chats'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    expect(find.text('Navigation'), findsWidgets);
  });

  testWidgets('arrow keys select Back and Enter leaves the group', (
    tester,
  ) async {
    final controller = PaletteController(
      registry: CommandRegistry([
        PaletteCommand(
          id: 'nav',
          titles: const LocalizedText(ru: 'Навигация', en: 'Navigation'),
        ),
        PaletteCommand(
          id: 'nav.chats',
          parentId: 'nav',
          titles: const LocalizedText(ru: 'Чаты', en: 'Chats'),
          action: const BuiltinPaletteAction('chats'),
        ),
      ]),
      searchApi: _NoSearchApi(),
      projects: const [],
      chats: const [],
      labels: _labels,
      languageCode: 'en',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CommandPaletteDialog(
            controller: controller,
            onCommand: (_) => throw StateError('unexpected command'),
            onHit: (_) => throw StateError('unexpected hit'),
            onClose: () => throw StateError('unexpected close'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Navigation').first);
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.text('Navigation'), findsWidgets);
  });

  testWidgets('filter suggestions open in an overlay as wide as the field', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 11, 13);
    final project = Project(
      id: 'p1',
      hostId: 'local',
      name: 'A very long project name that must be trimmed on a narrow screen',
      workspace: '/work',
      workspaceKey: '/work',
      createdAt: now,
      updatedAt: now,
    );
    final controller = PaletteController(
      registry: CommandRegistry([
        PaletteCommand(
          id: 'alpha',
          titles: const LocalizedText(ru: 'Альфа', en: 'Alpha'),
          action: const BuiltinPaletteAction('alpha'),
        ),
      ]),
      searchApi: _NoSearchApi(),
      projects: [project],
      chats: const [],
      labels: _labels,
      languageCode: 'en',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CommandPaletteDialog(
            controller: controller,
            onCommand: (_) => throw StateError('unexpected command'),
            onHit: (_) => throw StateError('unexpected hit'),
            onClose: () => throw StateError('unexpected close'),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '@project:');
    await tester.pump();

    expect(find.text(project.name), findsOneWidget);
    final fieldWidth = tester.getSize(find.byType(TextField)).width;
    final overlayList = find.ancestor(
      of: find.text(project.name),
      matching: find.byType(ListView),
    );
    final overlayWidth = tester.getSize(overlayList.first).width;
    expect(overlayWidth, closeTo(fieldWidth, 0.5));

    final title = tester.widget<Text>(find.text(project.name));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);

    await tester.tap(find.text(project.name));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '@project:"${project.name}" ',
    );
  });

  testWidgets('arrow keys choose a filter suggestion and Enter applies it', (
    tester,
  ) async {
    final controller = PaletteController(
      registry: CommandRegistry([
        PaletteCommand(
          id: 'alpha',
          titles: const LocalizedText(ru: 'Альфа', en: 'Alpha'),
          action: const BuiltinPaletteAction('alpha'),
        ),
      ]),
      searchApi: _NoSearchApi(),
      projects: const [],
      chats: const [],
      labels: _labels,
      languageCode: 'en',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CommandPaletteDialog(
            controller: controller,
            onCommand: (_) => throw StateError('unexpected command'),
            onHit: (_) => throw StateError('unexpected hit'),
            onClose: () => throw StateError('unexpected close'),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '@scope:');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '@scope:project ',
    );
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('arrow keys keep the last chat suggestion visible', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 11, 13);
    final chats = [
      for (var i = 0; i < 20; i++)
        Chat(
          id: 'c$i',
          hostId: 'local',
          title: 'Chat $i',
          createdAt: now,
          updatedAt: now,
        ),
    ];
    final controller = PaletteController(
      registry: CommandRegistry([
        PaletteCommand(
          id: 'alpha',
          titles: const LocalizedText(ru: 'Альфа', en: 'Alpha'),
          action: const BuiltinPaletteAction('alpha'),
        ),
      ]),
      searchApi: _NoSearchApi(),
      projects: const [],
      chats: chats,
      labels: _labels,
      languageCode: 'en',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CommandPaletteDialog(
            controller: controller,
            onCommand: (_) => throw StateError('unexpected command'),
            onHit: (_) => throw StateError('unexpected hit'),
            onClose: () => throw StateError('unexpected close'),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '@chat:');
    await tester.pump();
    expect(controller.suggestions, hasLength(12));
    for (var i = 0; i < 11; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final item = find.text('Chat 11');
    expect(item, findsOneWidget);
    final list = find.ancestor(of: item, matching: find.byType(ListView)).first;
    final itemRect = tester.getRect(item);
    final listRect = tester.getRect(list);
    expect(itemRect.top, greaterThanOrEqualTo(listRect.top - 0.5));
    expect(itemRect.bottom, lessThanOrEqualTo(listRect.bottom + 0.5));
  });

  testWidgets('suggestion tooltip does not break the overlay layout', (
    tester,
  ) async {
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
    final controller = PaletteController(
      registry: CommandRegistry([
        PaletteCommand(
          id: 'alpha',
          titles: const LocalizedText(ru: 'Альфа', en: 'Alpha'),
          action: const BuiltinPaletteAction('alpha'),
        ),
      ]),
      searchApi: _NoSearchApi(),
      projects: [project],
      chats: const [],
      labels: _labels,
      languageCode: 'en',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CommandPaletteDialog(
            controller: controller,
            onCommand: (_) => throw StateError('unexpected command'),
            onHit: (_) => throw StateError('unexpected hit'),
            onClose: () => throw StateError('unexpected close'),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), '@project:');
    await tester.pump();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text(project.name)));
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
  });
}
