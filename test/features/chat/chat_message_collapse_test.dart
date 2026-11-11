import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_message_tile.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';

ChatMessage _user(String id, String text, {int seq = 1}) => ChatMessage(
  id: id,
  chatId: 'c',
  seq: seq,
  role: MessageRole.user,
  createdAt: DateTime(2026),
  text: text,
);

ChatMessage _assistant(String id, String text, {int seq = 2}) => ChatMessage(
  id: id,
  chatId: 'c',
  seq: seq,
  role: MessageRole.assistant,
  createdAt: DateTime(2026),
  text: text,
);

ChatState _state(List<ChatMessage> messages) => ChatState(
  chatId: 'c',
  chat: Chat(
    id: 'c',
    hostId: 'local',
    title: 'Chat',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  ),
  messages: messages,
);

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SizedBox(height: 900, width: 800, child: child)),
  ),
);

Finder _userTile(String id) => find.byWidgetPredicate(
  (widget) => widget is ChatMessageTile && widget.message.id == id,
);

/// Расстояние от верха слота пользователя до текста ответа: прокрутка из него вычитается.
double _span(WidgetTester tester, Finder from, Finder to) =>
    tester.getTopLeft(to).dy - tester.getTopLeft(from).dy;

void main() {
  testWidgets('collapsing a long message drops the slot in the same frame', (
    tester,
  ) async {
    await _pump(
      tester,
      ChatTimeline(
        state: _state([
          _user('last', 'word ' * 800),
          _assistant('a', 'latest answer'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Show full message'));
    await tester.tap(find.text('Show full message'));
    await tester.pumpAndSettle();
    final expanded = tester.getSize(_userTile('last')).height;

    await tester.ensureVisible(find.text('Collapse'));
    await tester.tap(find.text('Collapse'));
    await tester.pump();

    final tile = tester.getRect(_userTile('last'));
    final answerTop = tester.getTopLeft(find.text('latest answer')).dy;
    expect(tile.height, lessThan(expanded - 200));
    // Слот выше пузыря оставил бы ответ далеко под уже короткой плиткой.
    expect(answerTop - tile.bottom, lessThan(48));
  });

  testWidgets('opening the editor still eases the bubble slot', (tester) async {
    const editorHeight = 240.0;
    const editorKey = ValueKey<String>('editor');
    final state = _state([
      _user('u', 'Fix the login'),
      _assistant('a', 'after the bubble'),
    ]);
    final answer = find.text('after the bubble');
    await _pump(tester, ChatTimeline(state: state));
    await tester.pumpAndSettle();
    final before = _span(tester, _userTile('u'), answer);

    await _pump(
      tester,
      ChatTimeline(
        state: state,
        editingMessageId: 'u',
        messageEditor: const SizedBox(key: editorKey, height: editorHeight),
      ),
    );
    await tester.pump();
    final during = _span(tester, find.byKey(editorKey), answer);

    await tester.pumpAndSettle();
    final settled = _span(tester, find.byKey(editorKey), answer);
    expect(settled, greaterThan(before + 100));
    expect(during, lessThan(before + (settled - before) * 0.75));
  });
}
