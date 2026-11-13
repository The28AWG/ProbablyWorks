import 'package:app_ui/app_ui.dart';
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
import 'package:pw_agent/agent/domain/search.dart';

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
}
