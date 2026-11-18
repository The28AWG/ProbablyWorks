import 'package:app_ui/app_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/shortcuts/keybinding_service.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/chat/presentation/widgets/mention_autocomplete.dart';
import 'package:probably_works/features/chat/presentation/widgets/mention_text_controller.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/workspace_entry.dart';

void main() {
  late MentionTextController controller;
  late List<bool> submits;

  setUp(() {
    controller = MentionTextController();
    submits = [];
  });

  tearDown(() => controller.dispose());

  Future<void> pump(
    WidgetTester tester, {
    Future<List<WorkspaceEntry>> Function(String query)? search,
    KeybindingService? keybindings,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: MentionComposerInput(
            controller: controller,
            hint: 'Message',
            busy: false,
            loading: false,
            maxLines: 6,
            onSubmit: submits.add,
            keybindings: keybindings,
            search:
                search ??
                (query) async => const [
                  WorkspaceEntry(path: 'README.md', isDirectory: false),
                  WorkspaceEntry(path: 'docs/README.md', isDirectory: false),
                ],
          ),
        ),
      ),
    ),
  );

  testWidgets('typing @rdm opens files and Enter selects instead of sending', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '@rdm');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('README.md'), findsWidgets);
    expect(find.text('docs/'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(submits, isEmpty);
    expect(controller.text, '@README.md ');
    expect(controller.mentions.single.path, 'README.md');
  });

  testWidgets('popup is above the field and has the field width', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '@rdm');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    final field = tester.getRect(find.byType(TextField));
    final item = tester.getRect(find.text('README.md').first);
    expect(item.bottom, lessThanOrEqualTo(field.top));
    expect(item.left, greaterThanOrEqualTo(field.left));
    expect(item.right, lessThanOrEqualTo(field.right));
  });

  testWidgets('keyboard navigation scrolls the popup to the selection', (
    tester,
  ) async {
    final entries = [
      for (var i = 0; i < 30; i++)
        WorkspaceEntry(path: 'src/file_$i.dart', isDirectory: false),
    ];
    await pump(tester, search: (query) async => entries);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '@file');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pumpAndSettle();

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.controller!.offset, greaterThan(0));
  });

  testWidgets('pasted token can become a mention by selecting from the list', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(TextField));
    controller.value = const TextEditingValue(
      text: '@README.md',
      selection: TextSelection.collapsed(offset: 10),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('README.md'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.mentions.single.path, 'README.md');
    expect(controller.text, '@README.md ');
  });

  testWidgets('Esc closes the list but keeps the existing mention', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byType(TextField));
    controller.value = const TextEditingValue(
      text: '@README.md',
      selection: TextSelection.collapsed(offset: 10),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.text('docs/'), findsNothing);
    expect(controller.mentions, isEmpty);
    expect(controller.text, '@README.md');
  });

  testWidgets('Ctrl+Space reopens a closed list without moving the caret', (
    tester,
  ) async {
    await pump(tester, keybindings: KeybindingService(MemoryClientSettings()));
    await tester.tap(find.byType(TextField));
    controller.value = const TextEditingValue(
      text: '@README.md',
      selection: TextSelection.collapsed(offset: 10),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('docs/'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('docs/'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('docs/'), findsOneWidget);
    expect(controller.text, '@README.md');
  });

  testWidgets('loading a draft does not open the list by itself', (
    tester,
  ) async {
    await pump(tester);
    controller.resetDraft('@README.md', const [
      MentionRef(kind: MentionKind.file, path: 'README.md', start: 0, end: 10),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('docs/'), findsNothing);
  });

  testWidgets('no search means no list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MentionComposerInput(
            controller: controller,
            hint: 'Message',
            busy: false,
            loading: false,
            maxLines: 6,
            onSubmit: submits.add,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '@rdm');
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('README.md'), findsNothing);
  });
}
