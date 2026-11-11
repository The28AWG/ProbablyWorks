import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_message_tile.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

ChatMessage _user(String text) => ChatMessage(
  id: 'u',
  chatId: 'c',
  seq: 1,
  role: MessageRole.user,
  createdAt: DateTime(2026),
  text: text,
);

class _Host extends StatelessWidget {
  const _Host(this.message);

  final ChatMessage message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: ChatMessageTile(message: message, editable: false),
      ),
    ),
  );
}

String _shownText(WidgetTester tester) =>
    tester.widget<SelectableText>(find.byType(SelectableText)).data!;

void main() {
  testWidgets('short user message is shown whole without a toggle', (
    tester,
  ) async {
    await tester.pumpWidget(_Host(_user('hello')));

    expect(_shownText(tester), 'hello');
    expect(find.text('Show full message'), findsNothing);
  });

  testWidgets(
    'long user message is truncated until expanded, then collapses back',
    (tester) async {
      final text = 'word ' * 1000;
      await tester.pumpWidget(_Host(_user(text)));

      expect(_shownText(tester).length, lessThan(text.length));
      expect(_shownText(tester), endsWith('…'));

      await tester.ensureVisible(find.text('Show full message'));
      await tester.tap(find.text('Show full message'));
      await tester.pump();
      expect(_shownText(tester), text);
      expect(find.text('Collapse'), findsOneWidget);

      await tester.ensureVisible(find.text('Collapse'));
      await tester.tap(find.text('Collapse'));
      await tester.pump();
      expect(_shownText(tester).length, lessThan(text.length));
    },
  );

  testWidgets('message of exactly the preview size has no toggle', (
    tester,
  ) async {
    final text = 'word ' * 400;
    await tester.pumpWidget(_Host(_user(text)));

    expect(_shownText(tester), text);
    expect(find.text('Show full message'), findsNothing);
  });
}
